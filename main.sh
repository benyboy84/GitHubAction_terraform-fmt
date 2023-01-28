#!/bin/bash

echo "INFO     | Checking if terraform file(s) are correctly formatted."

# check if variable is array, returns 0 on success, 1 otherwise
# @param mixed 

IS_ARRAY()
{   # Detect if arg is an array, returns 0 on sucess, 1 otherwise
    [ -z "$1" ] && return 1
    if [ -n "$BASH" ]; then
        declare -p ${1} 2> /dev/null | grep 'declare \-a' >/dev/null && return 0
    fi
    return 1
}

# `PULL_REQUEST_COMMENT` function will create a comment if the action is call from a pull request.
# If a comment already exist in the pull request, it will delete it and create a new one.
# If there EXITCODE variable is set to 0, meaning that there is no error, if a comment exist, it will be deleted.
# @param: pull request comment
#    Follow this guide to build the string for the body of the pull request comment:
#    https://github.com/adam-p/markdown-here/wiki/Markdown-Cheatsheets
PULL_REQUEST_COMMENT () {
    #if [[ "$GITHUB_EVENT_NAME" != "push" && "$GITHUB_EVENT_NAME" != "pull_request" && "$GITHUB_EVENT_NAME" != "issue_comment" && "$GITHUB_EVENT_NAME" != "pull_request_review_comment" && "$GITHUB_EVENT_NAME" != "pull_request_target" && "$GITHUB_EVENT_NAME" != "pull_request_review" ]]; then
    if [[ "$GITHUB_EVENT_NAME" != "pull_request" && "$GITHUB_EVENT_NAME" != "issue_comment" ]]; then
        echo "WARNING  | $GITHUB_EVENT_NAME event does not relate to a pull request."
    else
        if [[ -z GITHUB_TOKEN ]]; then
            echo "WARNING  | GITHUB_TOKEN not defined. Pull request comment is not possible without a GitHub token."
        else
            # Look for an existing pull request comment and delete
            echo "INFO     | Looking for an existing pull request comment."
            local ACCEPT_HEADER="Accept: application/vnd.github.v3+json"
            local AUTH_HEADER="Authorization: token $GITHUB_TOKEN"
            local CONTENT_HEADER="Content-Type: application/json"
            if [[ "$GITHUB_EVENT_NAME" == "issue_comment" ]]; then
                local PR_COMMENTS_URL=$(jq -r ".issue.comments_url" "$GITHUB_EVENT_PATH")
            else
                local PR_COMMENTS_URL=$(jq -r ".pull_request.comments_url" "$GITHUB_EVENT_PATH")
            fi
            local PR_COMMENT_URI=$(jq -r ".repository.issue_comment_url" "$GITHUB_EVENT_PATH" | sed "s|{/number}||g")
            local PR_COMMENT_ID=$(curl -sS -H "$AUTH_HEADER" -H "$ACCEPT_HEADER" -L "$PR_COMMENTS_URL" | jq '.[] | select(.body|test ("### Terraform Format")) | .id')
            if [ "$PR_COMMENT_ID" ]; then
                if [[ $(IS_ARRAY $PR_COMMENT_ID)  -ne 0 ]]; then
                    echo "INFO     | Found existing pull request comment: $PR_COMMENT_ID. Deleting."
                    local PR_COMMENT_URL="$PR_COMMENT_URI/$PR_COMMENT_ID"
                    {
                        curl -sS -X DELETE -H "$AUTH_HEADER" -H "$ACCEPT_HEADER" -L "$PR_COMMENT_URL" > /dev/null
                    } ||
                    {
                        echo "ERROR    | Unable to delete existing comment in pull request."
                    }
                else
                    echo "WARNING  | Pull request contain many comments with \"### Terraform Format\" in the body."
                    echo "WARNING  | Existing pull request comments won't be delete."
                fi
            else
                echo "INFO     | No existing pull request comment found."
            fi
            if [[ $EXITCODE -ne 0 ]]; then
                # Add comment to pull request.
                local PR_PAYLOAD=$(echo '{}' | jq --arg body "$1" '.body = $body')
                echo "INFO     | Adding comment to pull request."
                {
                    curl -sS -X POST -H "$AUTH_HEADER" -H "$ACCEPT_HEADER" -H "$CONTENT_HEADER" -d "$PR_PAYLOAD" -L "$PR_COMMENTS_URL" > /dev/null
                } ||
                {
                    echo "ERROR    | Unable to add comment to pull request."
                }
            fi
        fi
    fi
}

# Optional inputs

# Validate input target.
TARGET=""
if [[ -n "$INPUT_TARGET" ]]; then
    if [[ -d "$INPUT_TARGET" || -f "$INPUT_TARGET" ]]; then
        TARGET=$INPUT_TARGET
    else
        EXITCODE=1
        echo "ERROR    | Target does not exist: \"$INPUT_TARGET\"."
        PR_COMMENT="### Terraform Format Failed
<details><summary>Show Output</summary>
<p>
Provided value \"$INPUT_TARGET\" for \`target\` input does not exist. 
You need to provide an existing file or directory.
</p>
</details>"
        PULL_REQUEST_COMMENT "$PR_COMMENT"
        exit $EXITCODE
    fi
fi

# Validate input recursive.
RECURSIVE=""
if [[ ! "$INPUT_RECURSIVE" =~ ^(true|false)$ ]]; then
    EXITCODE=1
    echo "ERROR    | Unsupported command \"$INPUT_RECURSIVE\" for input \"Recursive\". Valid values are \"true\" or \"false\"."
    PR_COMMENT="### Terraform Format Failed
<details><summary>Show Output</summary>
<p>
Unsupported command \"$INPUT_RECURSIVE\" for input \"Recursive\". 
Valid values are \"true\" or \"false\".
</p>
</details>"
        PULL_REQUEST_COMMENT "$PR_COMMENT"
        exit $EXITCODE
fi
if [[ "$INPUT_RECURSIVE" == true ]]; then
    RECURSIVE="-recursive"
fi

# Detect terraform version
VERSION=$(terraform version -json | jq -r '.terraform_version' 2>/dev/null || terraform version | grep 'Terraform v' | sed 's/Terraform v//')
if [[ -z $VERSION  ]]; then
    EXITCODE=1
    echo "ERROR    | Terraform not detected."
    PR_COMMENT="### Terraform Format Failed
<details><summary>Show Output</summary>
<p>
This GitHub Actions does not install `terraform`, so you have to install them in advanced.

\`\`\`yaml
- name: Setup Terraform
uses: hashicorp/setup-terraform@v2
with:
    terraform_wrapper: false
\`\`\`

</p>
</details>"
        PULL_REQUEST_COMMENT "$PR_COMMENT"
        exit $EXITCODE
else
    echo "INFO     | Using terraform version $VERSION."
fi

# Gather the output of `terraform fmt`.
OUTPUT=$(terraform fmt -list=false -check ${RECURSIVE} ${TARGET})
EXITCODE=${?}

# Exit Code: 0
# Meaning: All files formatted correctly.
if [[ $EXITCODE -eq 0 ]]; then
    echo "INFO     | Terraform file(s) are correctly formatted"
fi

# Exit Code: 1, 2
# Meaning: 1 = Malformed Terraform CLI command. 2 = Terraform parse error.
# Actions: Build pull request comment.
if [[ $EXITCODE -eq 1 || $EXITCODE -eq 2 ]]; then
    if [[ $EXITCODE -eq 2 ]]; then
        echo "ERROR    | Failed to parse terraform file(s)."
    else
        echo "ERROR    | Malformed terraform CLI command."
    fi
    # Add output of `terraform fmt` command.
    echo -e "ERROR    | Terraform fmt output:"
    echo -e $OUTPUT
    PR_COMMENT="### Terraform Format Failed
<details><summary>Show Output</summary>
<p>
$OUTPUT
</p>
</details>"
fi

# Exit Code: 3
# Meaning: One or more files are incorrectly formatted.
# Actions: Iterate over all files and build diff-based pull request comment.
if [[ $EXITCODE -eq 3 ]]; then
    echo "ERROR    | Terraform file(s) are incorrectly formatted."
    # Add output of `terraform fmt` command.
    echo -e "ERROR    | Terraform fmt output:"
    echo -e $OUTPUT
    ALL_FILES_DIFF=""
    OUTPUT=""
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
        OUTPUT="$OUTPUT

$THIS_FILE_DIFF"
    done
    echo -e "ERROR    | Terraform fmt output:"
    echo -e "$OUTPUT"
    PR_COMMENT="### Terraform Format Failed 
$ALL_FILES_DIFF"
fi

PULL_REQUEST_COMMENT "$PR_COMMENT"

exit $EXITCODE
