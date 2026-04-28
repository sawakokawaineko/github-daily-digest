#!/usr/bin/env bash
#
# GitHub Daily Digest
#
# 当日（JST）の GitHub 活動を集計し、Slack Webhook に投稿する。
# 仕様: ~/Projects/matome-text/2026-04-27_github-daily-activity-notifier.md
#
# 環境変数:
#   GITHUB_TOKEN       (必須) fine-grained PAT。repo/read:user/read:org 権限。
#   SLACK_WEBHOOK_URL  (DRY_RUN=false のとき必須) Slack Incoming Webhook URL。
#   GITHUB_USERNAME    (任意) 既定値 azimicat
#   DRY_RUN            (任意) "true" のとき Slack 送信せず標準出力のみ。既定値 true。
#   SKIP_IF_EMPTY      (任意) "true" のとき活動0件で通知スキップ。既定値 true。
#
set -euo pipefail

GITHUB_USERNAME="${GITHUB_USERNAME:-azimicat}"
DRY_RUN="${DRY_RUN:-true}"
SKIP_IF_EMPTY="${SKIP_IF_EMPTY:-true}"

if [[ -z "${GITHUB_TOKEN:-}" ]]; then
  echo "ERROR: GITHUB_TOKEN が未設定です" >&2
  exit 1
fi

if [[ "${DRY_RUN}" != "true" && -z "${SLACK_WEBHOOK_URL:-}" ]]; then
  echo "ERROR: DRY_RUN!=true のとき SLACK_WEBHOOK_URL は必須です" >&2
  exit 1
fi

export GH_TOKEN="${GITHUB_TOKEN}"

TODAY_JST="$(TZ=Asia/Tokyo date '+%Y-%m-%d')"
WEEKDAY_NUM="$(TZ=Asia/Tokyo date '+%w')"
WEEKDAYS_JA=(日 月 火 水 木 金 土)
DAY_LABEL="${TODAY_JST} (${WEEKDAYS_JA[${WEEKDAY_NUM}]})"

EVENTS_JSON="$(gh api "/users/${GITHUB_USERNAME}/events" --paginate)"

# events feed の payload.pull_request は title/merged を含まないため、
# 当日の PR 関連イベントから (repo, number) を抽出して個別に PR 詳細を fetch する。
PR_REFS_JSON="$(
  echo "${EVENTS_JSON}" \
    | jq --arg today "${TODAY_JST}" --arg user "${GITHUB_USERNAME}" '
      def jst_date: (.created_at | fromdateiso8601 + (9*3600) | strftime("%Y-%m-%d"));
      [ .[]
        | select(.actor.login == $user)
        | select(jst_date == $today)
        | select(.type == "PullRequestEvent"
                 or .type == "PullRequestReviewEvent"
                 or .type == "PullRequestReviewCommentEvent")
        | {repo: .repo.name, number: .payload.pull_request.number}
      ] | unique_by("\(.repo)#\(.number)")
    '
)"

PR_DETAILS_JSON='{}'
while IFS= read -r ref; do
  [[ -z "${ref}" ]] && continue
  pr_repo="$(echo "${ref}" | jq -r '.repo')"
  pr_number="$(echo "${ref}" | jq -r '.number')"
  if pr_obj="$(gh api "/repos/${pr_repo}/pulls/${pr_number}" 2>/dev/null)"; then
    PR_DETAILS_JSON="$(
      jq --arg key "${pr_repo}#${pr_number}" --argjson pr "${pr_obj}" \
        '. + {($key): {title: $pr.title, merged: $pr.merged, html_url: $pr.html_url}}' \
        <<< "${PR_DETAILS_JSON}"
    )"
  fi
done < <(echo "${PR_REFS_JSON}" | jq -c '.[]')

# events feed は actor.login=user の events しか持たないため、
# 「他人が close/merge した自分の PR」は構造的に拾えない。
# Search API で author=user かつ当日 JST 内に close された PR を補完取得する。
SEARCH_START_UTC="$(jq -rn --arg d "${TODAY_JST}T00:00:00Z" '$d | fromdateiso8601 - 9*3600 | strftime("%Y-%m-%dT%H:%M:%SZ")')"
SEARCH_END_UTC="$(jq -rn --arg d "${TODAY_JST}T23:59:59Z" '$d | fromdateiso8601 - 9*3600 | strftime("%Y-%m-%dT%H:%M:%SZ")')"
CLOSED_PRS_SEARCH_JSON="$(
  gh api -X GET /search/issues \
    -f q="type:pr author:${GITHUB_USERNAME} closed:${SEARCH_START_UTC}..${SEARCH_END_UTC}" \
    -f per_page=100 \
    | jq '.items'
)"

DIGEST_JSON="$(
  echo "${EVENTS_JSON}" \
    | jq --arg today "${TODAY_JST}" --arg user "${GITHUB_USERNAME}" \
         --argjson pr_details "${PR_DETAILS_JSON}" \
         --argjson closed_prs_search "${CLOSED_PRS_SEARCH_JSON}" '
      def jst_date: (.created_at | fromdateiso8601 + (9*3600) | strftime("%Y-%m-%d"));
      def pr_key: "\(.repo.name)#\(.payload.pull_request.number)";
      def pr_title: $pr_details[pr_key].title;
      def pr_merged: ($pr_details[pr_key].merged // false);
      def pr_html_url: $pr_details[pr_key].html_url;

      def classify:
        .type as $t
        | (.payload.action // "") as $a
        | if   $t == "IssueCommentEvent"             then "comment"
          elif $t == "PullRequestReviewCommentEvent" then "comment"
          elif $t == "CommitCommentEvent"            then "comment"
          elif ($t == "IssuesEvent"      and $a == "opened") then "create"
          elif ($t == "PullRequestEvent" and $a == "opened") then "create"
          elif ($t == "PullRequestReviewEvent" and ((.payload.review.state // "") == "approved")) then "approve"
          elif ($t == "IssuesEvent"      and $a == "closed") then "close"
          elif ($t == "PullRequestEvent" and $a == "closed") then "close"
          else null
          end;

      def summarize:
        .type as $t
        | if   $t == "IssueCommentEvent"             then {kind: (if .payload.issue.pull_request then "pr" else "issue" end), number: .payload.issue.number, title: .payload.issue.title, url: .payload.comment.html_url}
          elif $t == "PullRequestReviewCommentEvent" then {kind: "pr",     number: .payload.pull_request.number, title: pr_title,             url: .payload.comment.html_url}
          elif $t == "CommitCommentEvent"            then {kind: "commit", number: null, sha: (.payload.comment.commit_id[0:7]), title: "(commit comment)", url: .payload.comment.html_url}
          elif $t == "IssuesEvent"                   then {kind: "issue",  number: .payload.issue.number,        title: .payload.issue.title, url: .payload.issue.html_url}
          elif $t == "PullRequestEvent"              then {kind: "pr",     number: .payload.pull_request.number, title: pr_title,             url: pr_html_url, merged: pr_merged}
          elif $t == "PullRequestReviewEvent"        then {kind: "pr",     number: .payload.pull_request.number, title: pr_title,             url: .payload.review.html_url}
          else null
          end;

      [ .[]
        | select(.actor.login == $user)
        | select(jst_date == $today)
        | (classify) as $cat
        | select($cat != null)
        | { category: $cat, repo: .repo.name, info: summarize, created_at: .created_at }
      ] as $events
      |
      ($events | map(select(.category == "create"))  | sort_by(.created_at)) as $creates
      | ($events | map(select(.category == "approve")) | sort_by(.created_at)) as $approves
      | ($events | map(select(.category == "close")))                          as $events_closes
      | ($events_closes | map("\(.repo)#\(.info.number)"))                      as $events_close_keys
      | ( $closed_prs_search
          | map({
              category: "close",
              repo: (.repository_url | split("/") | .[-2:] | join("/")),
              info: {
                kind: "pr",
                number: .number,
                title: .title,
                url: .html_url,
                merged: (.pull_request.merged_at != null)
              },
              created_at: (.pull_request.merged_at // .closed_at)
            })
          | map(select("\(.repo)#\(.info.number)" as $k | $events_close_keys | index($k) | not))
        ) as $search_closes
      | (($events_closes + $search_closes) | sort_by(.created_at)) as $closes
      | ($events
          | map(select(.category == "comment"))
          | group_by([.repo, (.info.number // -1), (.info.sha // "")])
          | map({
              repo:  .[0].repo,
              info:  .[0].info,
              count: length,
              latest: (map(.created_at) | max)
            })
          | sort_by(.latest)
        ) as $comments
      |
      { day:      $today,
        creates:  $creates,
        comments: $comments,
        approves: $approves,
        closes:   $closes,
        total:    (($events | length) + ($search_closes | length))
      }
  '
)"

TOTAL="$(echo "${DIGEST_JSON}" | jq '.total')"

if [[ "${TOTAL}" -eq 0 && "${SKIP_IF_EMPTY}" == "true" ]]; then
  echo "本日（${DAY_LABEL}）の活動はありません。通知をスキップしました。"
  exit 0
fi

MESSAGE="$(
  echo "${DIGEST_JSON}" \
    | jq -r --arg label "${DAY_LABEL}" '
      if .total == 0 then
        [
          "📅 GitHub Daily Digest — \($label)",
          "",
          "本日のGitHub上での活動はありません。"
        ]
      else
        def ref_label:
          ( if .info.kind == "pr"     then "PR #\(.info.number)"
            elif .info.kind == "issue" then "Issue #\(.info.number)"
            elif .info.kind == "commit" then "Commit @\(.info.sha)"
            else "#\(.info.number // .info.sha)"
            end ) as $label
          | if (.info.url // "") != "" then "<\(.info.url)|\($label)>" else $label end;

        [
          "📅 GitHub Daily Digest — \($label)"
        ]
        + ( if (.creates | length) > 0
            then ["", "✏️ Created (\(.creates | length))"]
                 + (.creates | map("• \(ref_label) [\(.repo)] \(.info.title)"))
            else [] end )
        + ( if (.comments | length) > 0
            then ["", "💬 Commented (\(.comments | length))"]
                 + (.comments | map(
                     "• \(ref_label) [\(.repo)] \(.info.title) (\(.count) comment\(if .count > 1 then "s" else "" end))"
                   ))
            else [] end )
        + ( if (.approves | length) > 0
            then ["", "✅ Approved (\(.approves | length))"]
                 + (.approves | map("• \(ref_label) [\(.repo)] \(.info.title)"))
            else [] end )
        + ( if (.closes | length) > 0
            then ["", "🔒 Closed / Merged (\(.closes | length))"]
                 + (.closes | map(
                     ( if (.info.merged // false) then "merged" else "closed" end ) as $state
                     | "• \(ref_label) [\(.repo)] \(.info.title) (\($state))"
                   ))
            else [] end )
        + [ "", "— total \(.total) events" ]
      end
      | join("\n")
    '
)"

if [[ "${DRY_RUN}" == "true" ]]; then
  echo "==== DRY RUN (Slack送信なし) ===="
  echo "${MESSAGE}"
  exit 0
fi

PAYLOAD="$(jq -n --arg text "${MESSAGE}" '{text: $text}')"
RESP_FILE="$(mktemp)"
trap 'rm -f "${RESP_FILE}"' EXIT

HTTP_STATUS="$(
  curl -sS -o "${RESP_FILE}" -w '%{http_code}' \
    -X POST -H 'Content-Type: application/json' \
    -d "${PAYLOAD}" \
    "${SLACK_WEBHOOK_URL}"
)"

if [[ "${HTTP_STATUS}" != "200" ]]; then
  echo "ERROR: Slack POST 失敗 (HTTP ${HTTP_STATUS})" >&2
  cat "${RESP_FILE}" >&2
  exit 1
fi

echo "Slack送信完了 (events=${TOTAL})"
