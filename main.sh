#!/bin/bash

# Optional inputs

# Validate input path.
TARGET=""
if [[ -n "$INPUT_PATH" ]]; then
    if [[ ! -d "$INPUT_PATH" ]]; then
        echo "Terraform Format | ERROR    | Path does not exist: \"$INPUT_PATH\"."
        exit 1
    else
        TARGET=$INPUT_PATH
    fi
fi

# Validate input recursive.
RECURSIVE=""
if [[ ! "$INPUT_RECURSIVE" =~ ^(true|false)$ ]]; then
    echo "Terraform Format | ERROR    | Unsupported command \"$INPUT_RECURSIVE\" for input \"Recursive\". Valid commands are \"true\", \"false\"."
    exit 1
fi
if [[ "$INPUT_RECURSIVE" == true ]]; then
    RECURSIVE="-recursive"
fi

# Detect terraform version
VERSION=$(terraform version -json | jq -r '.terraform_version' 2>/dev/null || terraform version | grep 'Terraform v' | sed 's/Terraform v//')
if [[ -z $VERSION  ]]; then
    echo "Terraform Format | ERROR    | Terraform not detected."
    exit 1
else
    echo "Terraform Format | INFO     | Using terraform version $VERSION."
fi

# Gather the output of `terraform fmt`.
echo "Terraform Format | INFO     | Checking if Terraform files are correctly formatted."
OUTPUT=$(terraform fmt -list=false -check ${RECURSIVE} ${TARGET})
EXITCODE=${?}

# Exit Code: 0
# Meaning: All files formatted correctly.
if [[ $EXITCODE -eq 0 ]]; then
    echo "Terraform Format | INFO     | Terraform files are correctly formatted"
fi

# Exit Code: 1, 2
# Meaning: 1 = Malformed Terraform CLI command. 2 = Terraform parse error.
# Actions: Build PR comment.
if [[ $EXITCODE -eq 1 || $EXITCODE -eq 2 ]]; then

    if [[ $EXITCODE -eq 2 ]]; then
        echo "Terraform Format | ERROR    | Failed to parse Terraform files."
    else
        echo "Terraform Format | ERROR    | Malformed Terraform CLI command."
    fi

    PR_COMMENT="### ${GITHUB_WORKFLOW} - Terraform fmt Failed
<details><summary>Show Output</summary>
<p>
$Output
</p>
</details>"
fi

# Exit Code: 3
# Meaning: One or more files are incorrectly formatted.
# Actions: Iterate over all files and build diff-based PR comment.
if [[ $EXITCODE -eq 3 ]]; then
    echo "Terraform Format | ERROR    | Terraform files are incorrectly formatted."
    ALL_FILES_DIFF=""
    FILES=$(terraform fmt -check -write=false -list ${RECURSIVE})
    for FILE in $FILES; do
        THIS_FILE_DIFF=$(terraform fmt -no-color -write=false -diff "$FILE")
        ALL_FILES_DIFF="$ALL_FILES_DIFF
<details><summary><code>$FILE</code></summary>
<p>

\`\`\`diff
$THIS_FILE_DIFF
\`\`\`

</p>
</details>"
    done

    PR_COMMENT="### ${GITHUB_WORKFLOW} - Terraform fmt Failed 
$ALL_FILES_DIFF"
fi

# Add comment if the action is call from a pull request.
#if [[ "$GITHUB_EVENT_NAME" != "push" && "$GITHUB_EVENT_NAME" != "pull_request" && "$GITHUB_EVENT_NAME" != "issue_comment" && "$GITHUB_EVENT_NAME" != "pull_request_review_comment" && "$GITHUB_EVENT_NAME" != "pull_request_target" && "$GITHUB_EVENT_NAME" != "pull_request_review" ]]; then
if [[ "$GITHUB_EVENT_NAME" != "pull_request" && "$GITHUB_EVENT_NAME" != "issue_comment" ]]; then
    echo "Terraform Format | WARNING  | $GITHUB_EVENT_NAME event does not relate to a pull request."
    echo "Terraform Format | INFO     | Terraform format output"
    echo -e "$OUTPUT"
else
    if [[ -z GITHUB_TOKEN ]]; then
        echo "Terraform Format | WARNING  | GITHUB_TOKEN not defined. Pull request comment is not possible without a GitHub token."
    else
        # Look for an existing fmt PR comment and delete
        echo "Terraform Format | INFO     | Looking for an existing fmt PR comment."
        ACCEPT_HEADER="Accept: application/vnd.github.v3+json"
        AUTH_HEADER="Authorization: token $GITHUB_TOKEN"
        CONTENT_HEADER="Content-Type: application/json"
        if [[ "$GITHUB_EVENT_NAME" == "issue_comment" ]]; then
            PR_COMMENTS_URL=$(jq -r ".issue.comments_url" "$GITHUB_EVENT_PATH")
        else
            PR_COMMENTS_URL=$(jq -r ".pull_request.comments_url" "$GITHUB_EVENT_PATH")
        fi
        PR_COMMENT_URI=$(jq -r ".repository.issue_comment_url" "$GITHUB_EVENT_PATH" | sed "s|{/number}||g")
        PR_COMMENT_ID=$(curl -sS -H "$AUTH_HEADER" -H "$ACCEPT_HEADER" -L "$PR_COMMENTS_URL" | jq '.[] | select(.body|test ("### '"${GITHUB_WORKFLOW}"' - Terraform fmt Failed")) | .id')
        
        if [ "$PR_COMMENT_ID" ]; then
            echo "Terraform Format | INFO     | Found existing fmt PR comment: $PR_COMMENT_ID. Deleting."
            PR_COMMENT_URL="$PR_COMMENT_URI/$PR_COMMENT_ID"
            {
                curl -sS -X DELETE -H "$AUTH_HEADER" -H "$ACCEPT_HEADER" -L "$PR_COMMENT_URL" > /dev/null
            } ||
            {
                echo "Terraform Format | ERROR    | Unable to delete existing fmt failure comment in PR."
            }
        else
            echo "Terraform Format | INFO     | No existing fmt PR comment found."
        fi
        if [[ $EXITCODE -ne 0 ]]; then
            # Add fmt failure comment to PR.
            PR_PAYLOAD=$(echo '{}' | jq --arg body "$Pr_Comment" '.body = $body')
            echo "Terraform Format | INFO     | Adding fmt failure comment to PR."
            {
                curl -sS -X POST -H "$AUTH_HEADER" -H "$ACCEPT_HEADER" -H "$CONTENT_HEADER" -d "$PR_PAYLOAD" -L "$PR_COMMENTS_URL" > /dev/null
            } ||
            {
                echo "Terraform Format | ERROR    | Unable to add fmt failure comment to PR."
            }
        fi
    fi
fi
exit $ExitCode