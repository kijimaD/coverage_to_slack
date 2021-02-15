###
# Post coverage rate to Slack
#
# Usage: bash circleci-coverage-slack.sh [cobertura|jacoco]
#
# Required environment variables:
#
# - CIRCLE_TOKEN: project-specific readonly API token (need to access build artifacts for others)
# - SLACK_ENDPOINT: Slack endpoint url
# - COVERAGE_FILE: coverage xml filename (default: coverage.xml)
# - MAX_BUILD_HISTORY: max history num to fetch old rate (default: 5)
# - COMMIT_AUTHOR: Author of this commit
# - COMMIT_LOG: Log message of this commit
#

calcCoberturaRate() {
  local script="
import sys
import xml.etree.ElementTree as ET
root = ET.fromstring(sys.stdin.read())
print('%.2f' % (float(root.attrib['line-rate']) * 100))
"
  local rate=$(python -c "$script")
  [ "$rate" = "100.00" ] && rate=100
  echo $rate
}

calcJacocoRate() {
  local script="
import sys
import xml.etree.ElementTree as ET
root = ET.fromstring(sys.stdin.read())
counter = [child for child in root if child.tag == 'counter' and child.attrib['type'] == 'LINE'][0]
covered = float(counter.attrib['covered'])
missed = float(counter.attrib['missed'])
print('%.2f' % ( covered / (covered + missed) * 100))
"
  local rate=$(python -c "$script")
  [ "$rate" = "100.00" ] && rate=100
  echo $rate
}

calcRate() {
  case "$coverage_type" in
    "cobertura" )
      calcCoberturaRate
      ;;
    "jacoco" )
      calcJacocoRate
      ;;
  esac
}

coverage_type=${1:-cobertura}
url_base="https://circleci.com/api/v1.1/project/gh/${CIRCLE_PROJECT_USERNAME}/${CIRCLE_PROJECT_REPONAME}"
script="
import json
import sys
root = json.loads(sys.stdin.read())
for child in root:
  print(child['url'])
"

## calculate rates
echo "fetching coverage info for build:${CIRCLE_BUILD_NUM} ..."
artifacts="${url_base}/${CIRCLE_BUILD_NUM}/artifacts"

coverage=$(curl -s -L -H 'Accept: application/json' -H "Circle-Token: $CIRCLE_TOKEN" $artifacts | python -c "$script" | grep ${COVERAGE_FILE:-coverage.xml})
[ -z "$coverage" ] && exit
rate_new=$(curl -s -L -H "Circle-Token: $CIRCLE_TOKEN" $coverage | calcRate)

rate_old=0
for build_num in $(echo $CIRCLE_PREVIOUS_BUILD_NUM; seq $(expr $CIRCLE_BUILD_NUM - 1) -1 1 | head -n ${MAX_BUILD_HISTORY:-5}); do
  echo "fetching coverage info for build:${build_num} ..."
  artifacts="${url_base}/${build_num}/artifacts"
  coverage=$(curl -s -L -H 'Accept: application/json' -H "Circle-Token: $CIRCLE_TOKEN" $artifacts | python -c "$script" | grep ${COVERAGE_FILE:-coverage.xml})
  [ -n "$coverage" ] && break
done
if [ -n "$coverage" ]; then
  rate_old=$(curl -s -L -H "Circle-Token: $CIRCLE_TOKEN" $coverage | calcRate)
fi

## construct messages
mode=$(python -c "print(1 if $rate_new == $rate_old else 0 if $rate_new < $rate_old else 2)")
mes=$([ $mode -eq 0 ] && echo "DECREASED" || ([ $mode -eq 1 ] && echo "NOT CHANGED" || echo "INCREASED"))
color=$([ $mode -eq 0 ] && echo "danger" || ([ $mode -eq 1 ] && echo "#a0a0a0" || echo "good"))
cat > .slack_payload <<_EOT_
{
  "attachments": [
    {
      "fallback": "Coverage ${mes} (${rate_new}%)",
      "text": "*${mes}* (${rate_old}% -> ${rate_new}%)",
      "pretext": "Coverage report: <https://circleci.com/gh/${CIRCLE_PROJECT_USERNAME}/${CIRCLE_PROJECT_REPONAME}/${CIRCLE_BUILD_NUM}|#${CIRCLE_BUILD_NUM}> <https://circleci.com/gh/${CIRCLE_PROJECT_USERNAME}/${CIRCLE_PROJECT_REPONAME}|${CIRCLE_PROJECT_USERNAME}/${CIRCLE_PROJECT_REPONAME}> (<https://circleci.com/gh/${CIRCLE_PROJECT_USERNAME}/${CIRCLE_PROJECT_REPONAME}/tree/${CIRCLE_BRANCH}|${CIRCLE_BRANCH}>)",
      "color": "${color}",
      "mrkdwn_in": ["pretext", "text", "fields"],
      "fields": [
        {
          "value": "Commit: <https://github.com/${CIRCLE_PROJECT_USERNAME}/${CIRCLE_PROJECT_REPONAME}/commit/${CIRCLE_SHA1}|${CIRCLE_SHA1}>",
          "short": false
        },
        {
          "value": "Author: ${COMMIT_AUTHOR}",
          "short": false
        },
        {
          "value": "${COMMIT_LOG}",
          "short": false
        }
      ]
    }
  ]
}
_EOT_

## post to slack
curl -s --data-urlencode payload@.slack_payload ${SLACK_ENDPOINT}
rm .slack_payload