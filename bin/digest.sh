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
DAY_LABEL="$(TZ=Asia/Tokyo date '+%Y-%m-%d (%a)')"

EVENTS_JSON="$(gh api "/users/${GITHUB_USERNAME}/events" --paginate)"

DIGEST_JSON="$(
  echo "${EVENTS_JSON}" \
    | jq --arg today "${TODAY_JST}" --arg user "${GITHUB_USERNAME}" '
      def jst_date: (.created_at | fromdateiso8601 + (9*3600) | strftime("%Y-%m-%d"));

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
        | if   $t == "IssueCommentEvent"             then {number: .payload.issue.number,        title: .payload.issue.title,        url: .payload.comment.html_url}
          elif $t == "PullRequestReviewCommentEvent" then {number: .payload.pull_request.number, title: .payload.pull_request.title, url: .payload.comment.html_url}
          elif $t == "CommitCommentEvent"            then {number: null, sha: (.payload.comment.commit_id[0:7]), title: "(commit comment)", url: .payload.comment.html_url}
          elif $t == "IssuesEvent"                   then {number: .payload.issue.number,        title: .payload.issue.title,        url: .payload.issue.html_url}
          elif $t == "PullRequestEvent"              then {number: .payload.pull_request.number, title: .payload.pull_request.title, url: .payload.pull_request.html_url, merged: .payload.pull_request.merged}
          elif $t == "PullRequestReviewEvent"        then {number: .payload.pull_request.number, title: .payload.pull_request.title, url: .payload.review.html_url}
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
      | ($events | map(select(.category == "close"))   | sort_by(.created_at)) as $closes
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
        total:    ($events | length)
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
        [
          "📅 GitHub Daily Digest — \($label)"
        ]
        + ( if (.creates | length) > 0
            then ["", "✏️ Created (\(.creates | length))"]
                 + (.creates | map("• #\(.info.number) [\(.repo)] \(.info.title)"))
            else [] end )
        + ( if (.comments | length) > 0
            then ["", "💬 Commented (\(.comments | length))"]
                 + (.comments | map(
                     ( if .info.number != null
                         then "#\(.info.number)"
                         else "@\(.info.sha)"
                       end
                     ) as $ref
                     | "• \($ref) [\(.repo)] (\(.count) comment\(if .count > 1 then "s" else "" end))"
                   ))
            else [] end )
        + ( if (.approves | length) > 0
            then ["", "✅ Approved (\(.approves | length))"]
                 + (.approves | map("• #\(.info.number) [\(.repo)] \(.info.title)"))
            else [] end )
        + ( if (.closes | length) > 0
            then ["", "🔒 Closed / Merged (\(.closes | length))"]
                 + (.closes | map(
                     ( if (.info.merged // false) then "merged" else "closed" end ) as $state
                     | "• #\(.info.number) [\(.repo)] \(.info.title) (\($state))"
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
