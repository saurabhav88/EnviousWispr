#!/usr/bin/env bash
# The release-summary job's decision and report (moved out of release.yml by #3729 so
# its decisions have fixture tests; the logic and messages are the former inline block,
# plus the preflight-failure and verify-downloads rows).
#
#   release-summary.sh            reads the env below, appends to $GITHUB_STEP_SUMMARY
#   release-summary.sh --self-test
#
# Env: VERSION TAG SOURCE_RUN MODE DRY_RUN PREFLIGHT_RESULT BUILD_RESULT LAUNCH_RESULT
#      RELEASE_RESULT APPCAST_JOB_RESULT APPCAST_DELIVERY_RESULT SENTRY_RESULT CASK_RESULT
#      DOWNLOADS_RESULT DOWNLOADS_STATE SENTRY_ORG SENTRY_PROJECT DISCORD_RELEASE_WEBHOOK
#      RUN_URL GITHUB_STEP_SUMMARY
# Exit 1 only for a HEART failure (preflight, build, launch, GitHub Release).
set -euo pipefail

summarize() {
  local VERSION="${VERSION:-}" TAG="${TAG:-}" SOURCE_RUN="${SOURCE_RUN:-}" MODE="${MODE:-full}"
  local DRY_RUN="${DRY_RUN:-false}" PREFLIGHT_RESULT="${PREFLIGHT_RESULT:-success}"
  local DOWNLOADS_RESULT="${DOWNLOADS_RESULT:-skipped}" DOWNLOADS_STATE="${DOWNLOADS_STATE:-}"
  local out="${GITHUB_STEP_SUMMARY:-/dev/stdout}"

  # #3729: preflight now fails a new release whose committed notes or probes are missing;
  # the summary used to be skipped then, so the run showed no reason in one place.
  if [[ "$PREFLIGHT_RESULT" != "success" ]]; then
    {
      echo "## Release stopped at preflight — ${TAG:-unknown tag}"
      echo ""
      echo "Preflight ended \`${PREFLIGHT_RESULT}\`; nothing was built or published. Its log names the reason (for a new release: missing or skeleton \`.github/release-notes/v<V>.md\` or \`.probes\`, a bad tag, or a missing secret)."
    } >> "$out"
    echo "::error::HEART FAILURE: preflight ${PREFLIGHT_RESULT} — release did not start"
    return 1
  fi

  # #1117: a dry_run rehearsal ends every job in `success` (mutations are
  # gated/no-op'd), so distinguish it from a real shipped release in the
  # summary — an operator must never read a rehearsal as "shipped".
  local SUMMARY_TITLE
  if [[ "${DRY_RUN}" == "true" ]]; then
    SUMMARY_TITLE="DRY RUN (rehearsal — nothing shipped) — v${VERSION}"
  else
    SUMMARY_TITLE="Release Summary — v${VERSION}"
  fi

  status_emoji() {
    case "$1" in
      success|delivered|verified) echo "✅" ;;
      skipped|dry-run|not-applicable) echo "⏭️" ;;
      *)       echo "❌" ;;
    esac
  }

  # `publish-appcast` is intentionally skipped for release-only,
  # sentry-only, and build-only modes. Every other empty/unknown output
  # fails closed: the job ended before it could prove public delivery.
  local APPCAST_STATE
  if [[ "${APPCAST_JOB_RESULT:-skipped}" == "skipped" ]]; then
    APPCAST_STATE="skipped"
  elif [[ "$APPCAST_JOB_RESULT" != "success" ]]; then
    APPCAST_STATE="failed"
    echo "::warning::Appcast job ended ${APPCAST_JOB_RESULT}; treating delivery as failed."
  else
    case "${APPCAST_DELIVERY_RESULT:-}" in
      dry-run|delivered|pending-pr|failed) APPCAST_STATE="$APPCAST_DELIVERY_RESULT" ;;
      *)
        APPCAST_STATE="failed"
        echo "::warning::Appcast job produced no recognized delivery result; treating delivery as failed."
        ;;
    esac
  fi

  # #3729: verify-downloads is a limb. Skipped when nothing was published; a success
  # must carry a recognized state, anything else fails closed.
  local DOWNLOADS
  if [[ "$DOWNLOADS_RESULT" == "skipped" ]]; then
    DOWNLOADS="skipped"
  elif [[ "$DOWNLOADS_RESULT" != "success" ]]; then
    DOWNLOADS="failed"
  else
    case "$DOWNLOADS_STATE" in
      verified|not-applicable|dry-run) DOWNLOADS="$DOWNLOADS_STATE" ;;
      *) DOWNLOADS="failed" ;;
    esac
  fi

  local BUILD_RESULT="${BUILD_RESULT:-skipped}" LAUNCH_RESULT="${LAUNCH_RESULT:-skipped}"
  local RELEASE_RESULT="${RELEASE_RESULT:-skipped}" SENTRY_RESULT="${SENTRY_RESULT:-skipped}"
  local CASK_RESULT="${CASK_RESULT:-skipped}"
  local NEEDS_FOLLOWUP="No" FOLLOWUP_ITEMS=""
  if [[ "$APPCAST_STATE" == "failed" || "$APPCAST_STATE" == "pending-pr" ]]; then
    NEEDS_FOLLOWUP="Yes"
    FOLLOWUP_ITEMS="${FOLLOWUP_ITEMS}\n- Appcast: \`gh workflow run release.yml -f mode=appcast-only -f tag=${TAG} -f source_run_id=${SOURCE_RUN}\`"
  fi
  if [[ "$SENTRY_RESULT" != "success" && "$SENTRY_RESULT" != "skipped" ]]; then
    NEEDS_FOLLOWUP="Yes"
    FOLLOWUP_ITEMS="${FOLLOWUP_ITEMS}\n- Sentry: \`gh workflow run release.yml -f mode=sentry-only -f tag=${TAG} -f source_run_id=${SOURCE_RUN}\`"
  fi
  if [[ "$CASK_RESULT" != "success" && "$CASK_RESULT" != "skipped" ]]; then
    NEEDS_FOLLOWUP="Yes"
    FOLLOWUP_ITEMS="${FOLLOWUP_ITEMS}\n- Homebrew cask: \`gh workflow run bump-cask.yml -R saurabhav88/homebrew-tap -f version=${VERSION}\`"
  fi
  if [[ "$DOWNLOADS" == "failed" ]]; then
    NEEDS_FOLLOWUP="Yes"
    FOLLOWUP_ITEMS="${FOLLOWUP_ITEMS}\n- Downloads: compare \`shasum -a 256\` of both ${TAG} DMGs and of https://enviouswispr.com/download (see the verify-downloads log)"
  fi

  cat >> "$out" << SUMMARY
## ${SUMMARY_TITLE}

| Component | Status | Type |
|---|---|---|
| Build/Package | $(status_emoji "$BUILD_RESULT") \`${BUILD_RESULT}\` | **HEART** |
| Launch on macOS 14 (as shipped) | $(status_emoji "$LAUNCH_RESULT") \`${LAUNCH_RESULT}\` | **HEART** |
| GitHub Release | $(status_emoji "$RELEASE_RESULT") \`${RELEASE_RESULT}\` | **HEART** |
| Appcast | $(status_emoji "$APPCAST_STATE") \`${APPCAST_STATE}\` | limb |
| Sentry dSYMs | $(status_emoji "$SENTRY_RESULT") \`${SENTRY_RESULT}\` | limb |
| Homebrew cask | $(status_emoji "$CASK_RESULT") \`${CASK_RESULT}\` | limb |
| Downloads (both DMGs, website button) | $(status_emoji "$DOWNLOADS") \`${DOWNLOADS}\` | limb |

| Detail | Value |
|---|---|
| Mode | \`${MODE}\` |
| Source run ID | \`${SOURCE_RUN}\` |
| Manual follow-up needed | **${NEEDS_FOLLOWUP}** |
SUMMARY

  if [[ "$NEEDS_FOLLOWUP" == "Yes" ]]; then
    echo -e "\n### Recovery commands\n${FOLLOWUP_ITEMS}" >> "$out"
  fi

  # Fail the summary job only if HEART jobs failed
  if [[ "$BUILD_RESULT" != "success" && "$BUILD_RESULT" != "skipped" ]]; then
    echo "::error::HEART FAILURE: Build failed — release did not ship"
    return 1
  fi
  # #3348: a failed or cancelled launch gate SKIPS publishing, so RELEASE_RESULT
  # reads `skipped` and would pass the check below; name the gate itself.
  if [[ "$LAUNCH_RESULT" != "success" && "$LAUNCH_RESULT" != "skipped" ]]; then
    echo "::error::HEART FAILURE: the shipped app did not launch on macOS 14 (${LAUNCH_RESULT}) — release not published"
    return 1
  fi
  if [[ "$RELEASE_RESULT" != "success" && "$RELEASE_RESULT" != "skipped" ]]; then
    echo "::error::HEART FAILURE: GitHub Release failed — release did not ship"
    return 1
  fi

  # #1117: dry_run rehearsal — report as a rehearsal, never as "shipped".
  if [[ "${DRY_RUN}" == "true" ]]; then
    echo "==> DRY RUN v${VERSION} complete — pipeline rehearsed on its runners, NOTHING shipped (no GitHub Release, no appcast push, no Sentry upload)."
    return 0
  fi

  # Limb failures are warnings, not errors. Reaching here means we passed the
  # heart-failure exit guards AND the dry_run gate above, so this is a real
  # release that actually shipped. Push a proactive Discord alert (the backup
  # for unattended releases). Non-blocking: it can never fail the summary job,
  # but its absence/failure is made VISIBLE (#1088).
  if [[ "$NEEDS_FOLLOWUP" == "Yes" ]]; then
    echo "::warning::Limb failures detected — release shipped but follow-up needed. See summary for recovery commands."
    if [[ -z "${DISCORD_RELEASE_WEBHOOK:-}" ]]; then
      echo "::warning::DISCORD_RELEASE_WEBHOOK not configured — proactive alert NOT sent."
      echo "| Discord alert | NOT configured |" >> "$out"
    else
      local MSG PAYLOAD CODE
      MSG=$(printf 'RELEASE FOLLOW-UP NEEDED. v%s shipped to users, but a release limb needs attention.\nFollow-up:%b\nRun: %s\nSentry: %s / %s' \
        "$VERSION" "${FOLLOWUP_ITEMS}" "${RUN_URL:-}" "${SENTRY_ORG:-?}" "${SENTRY_PROJECT:-?}")
      PAYLOAD=$(python3 -c 'import json,sys; print(json.dumps({"content": sys.argv[1]}))' "$MSG")
      CODE=$(curl -sS -o /dev/null -w '%{http_code}' -X POST "$DISCORD_RELEASE_WEBHOOK" \
        -H "Content-Type: application/json" -d "$PAYLOAD" || echo "000")
      if [[ "$CODE" == "204" || "$CODE" == "200" ]]; then
        echo "| Discord alert | sent ($CODE) |" >> "$out"
      else
        echo "::warning::Discord alert POST failed (HTTP $CODE) — GitHub summary is the fallback record."
        echo "| Discord alert | attempted, failed ($CODE) |" >> "$out"
      fi
    fi
  else
    echo "==> Release v${VERSION} fully shipped. All components successful."
  fi
}

# shellcheck disable=SC2163,SC2016 # self-test: exports caller-supplied NAME=VALUE pairs; echo-only && || reporting; literal needles
self_test() {
  local tmp fails=0
  tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' RETURN
  base=(VERSION=2.5.5 TAG=v2.5.5 SOURCE_RUN=1 MODE=full DRY_RUN=false PREFLIGHT_RESULT=success
        BUILD_RESULT=success LAUNCH_RESULT=success RELEASE_RESULT=success
        APPCAST_JOB_RESULT=success APPCAST_DELIVERY_RESULT=delivered SENTRY_RESULT=success
        CASK_RESULT=success DOWNLOADS_RESULT=success DOWNLOADS_STATE=verified DISCORD_RELEASE_WEBHOOK=)
  case_() { # name, want-rc, grep-in-summary, env overrides...
    local name="$1" want="$2" needle="$3"; shift 3
    : > "$tmp/sum"
    local got
    if (export "${base[@]}" GITHUB_STEP_SUMMARY="$tmp/sum"; if [ $# -gt 0 ]; then export "$@"; fi; summarize) > "$tmp/log" 2>&1
    then got=0; else got=$?; fi
    if [ "$got" -eq "$want" ] && grep -qF -- "$needle" "$tmp/sum" "$tmp/log"; then echo "ok   $name"
    else echo "FAIL $name (rc $got want $want; needle '$needle')"; sed 's/^/     /' "$tmp/sum" "$tmp/log" | head -20; fails=$((fails + 1)); fi
  }
  case_ "all green ships" 0 "fully shipped"
  case_ "downloads verified row" 0 '✅ `verified`'
  case_ "preflight failure reported, heart fail" 1 "Release stopped at preflight" PREFLIGHT_RESULT=failure VERSION=
  case_ "downloads job failure needs follow-up" 0 "- Downloads:" DOWNLOADS_RESULT=failure DOWNLOADS_STATE=
  case_ "downloads success without a state fails closed" 0 '❌ `failed`' DOWNLOADS_STATE=
  case_ "downloads not applicable is not a follow-up" 0 "**No**" DOWNLOADS_STATE=not-applicable
  case_ "downloads skipped (build-only) is fine" 0 '⏭️ `skipped`' DOWNLOADS_RESULT=skipped RELEASE_RESULT=skipped APPCAST_JOB_RESULT=skipped MODE=build-only
  case_ "dry run reported as rehearsal" 0 "NOTHING shipped" DRY_RUN=true DOWNLOADS_STATE=dry-run APPCAST_DELIVERY_RESULT=dry-run
  case_ "build failure is a heart failure" 1 "Build failed" BUILD_RESULT=failure RELEASE_RESULT=skipped
  case_ "launch failure is a heart failure" 1 "did not launch" LAUNCH_RESULT=failure RELEASE_RESULT=skipped
  case_ "release failure is a heart failure" 1 "GitHub Release failed" RELEASE_RESULT=failure
  case_ "appcast pending-pr needs follow-up" 0 "mode=appcast-only" APPCAST_DELIVERY_RESULT=pending-pr
  case_ "no webhook is made visible" 0 "NOT configured" CASK_RESULT=failure
  echo "release-summary self-test: failures=$fails"
  [ "$fails" -eq 0 ]
}

if [ "${1:-}" = "--self-test" ]; then self_test; exit $?; fi
summarize
