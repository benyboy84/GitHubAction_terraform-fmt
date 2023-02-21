#!/bin/bash

echo "INFO     | Checking if terraform file(s) are correctly formatted."

# check if variable is array, returns 0 on success, 1 otherwise
# @param: mixed 
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
# If there `exit_code` variable is set to 0, meaning that there is no error, if a comment exist, it will be deleted.
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
            local accept_header="Accept: application/vnd.github.v3+json"
            local auth_header="Authorization: token $GITHUB_TOKEN"
            local content_header="Content-Type: application/json"
            if [[ "$GITHUB_EVENT_NAME" == "issue_comment" ]]; then
                local pr_comments_url=$(jq -r ".issue.comments_url" "$GITHUB_EVENT_PATH")
            else
                local pr_comments_url=$(jq -r ".pull_request.comments_url" "$GITHUB_EVENT_PATH")
            fi
            local pr_comment_uri=$(jq -r ".repository.issue_comment_url" "$GITHUB_EVENT_PATH" | sed "s|{/number}||g")
            local pr_comment_id=$(curl -sS -H "$auth_header" -H "$accept_header" -L "$pr_comments_url" | jq '.[] | select(.body|test ("### Terraform Format")) | .id')
            if [ "$pr_comment_id" ]; then
                if [[ $(IS_ARRAY $pr_comment_id)  -ne 0 ]]; then
                    echo "INFO     | Found existing pull request comment: $pr_comment_id. Deleting."
                    local pr_comment_url="$pr_comment_uri/$pr_comment_id"
                    {
                        curl -sS -X DELETE -H "$auth_header" -H "$accept_header" -L "$pr_comment_url" > /dev/null
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
            if [[ $exit_code -ne 0 ]]; then
                # Add comment to pull request.
                local body="### Terraform Format Failed
$1"
                local pr_payload=$(echo '{}' | jq --arg body "$body" '.body = $body')
                echo "INFO     | Adding comment to pull request."
                {
                    curl -sS -X POST -H "$auth_header" -H "$accept_header" -H "$content_header" -d "$pr_payload" -L "$pr_comments_url" > /dev/null
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
target=""
if [[ -n "$INPUT_TARGET" ]]; then
    if [[ -d "$INPUT_TARGET" || -f "$INPUT_TARGET" ]]; then
        target=$INPUT_TARGET
    else
        exit_code=1
        echo "ERROR    | Target does not exist: \"$INPUT_TARGET\"."
        pr_comment="Provided value \"$INPUT_TARGET\" for \`target\` input does not exist. 
You need to provide an existing file or directory."
        PULL_REQUEST_COMMENT "$pr_comment"
        exit $exit_code
    fi
fi

# Validate input recursive.
recursive=""
echo "INPUT_RECURSIVE: ${INPUT_RECURSIVE}"
echo "RECURSIVE: ${RECURSIVE}"
if [[ ! "$INPUT_RECURSIVE" =~ ^(true|false)$ ]]; then
    exit_code=1
    echo "ERROR    | Unsupported command \"$INPUT_RECURSIVE\" for input \"Recursive\". Valid values are \"true\" or \"false\"."
    pr_comment="Unsupported command \"$INPUT_RECURSIVE\" for input \`recursive\` input. 
Valid values are \"true\" or \"false\"."
        PULL_REQUEST_COMMENT "$pr_comment"
        exit $exit_code
fi
if [[ "$INPUT_RECURSIVE" == true ]]; then
    recursive="-recursive"
fi

# Detect terraform version
version=$(terraform version -json | jq -r '.terraform_version' 2>/dev/null || terraform version | grep 'Terraform v' | sed 's/Terraform v//')
if [[ -z $version  ]]; then
    exit_code=1
    echo "ERROR    | Terraform not detected."
    pr_comment="<details><summary>Show Output</summary>
<p>
This GitHub Actions does not install \`terraform\`, so you have to install them in advanced.

\`\`\`yaml
- name: Setup Terraform
uses: hashicorp/setup-terraform@v2
with:
    terraform_wrapper: false
\`\`\`

</p>
</details>"
        PULL_REQUEST_COMMENT "$pr_comment"
        exit $exit_code
else
    echo "INFO     | Using terraform version $version."
fi

# Gather the output of `terraform fmt`.
output=$(terraform fmt -list=false -check ${recursive} ${target})
exit_code=${?}

# Exit Code: 0
# Meaning: All files formatted correctly.
if [[ $exit_code -eq 0 ]]; then
    echo "INFO     | Terraform file(s) are correctly formatted"
fi

# Exit Code: 1, 2
# Meaning: 1 = Malformed Terraform CLI command. 2 = Terraform parse error.
# Actions: Build pull request comment.
if [[ $exit_code -eq 1 || $exit_code -eq 2 ]]; then
    if [[ $exit_code -eq 2 ]]; then
        echo "ERROR    | Failed to parse terraform file(s)."
    else
        echo "ERROR    | Malformed terraform CLI command."
    fi
    # Add output of `terraform fmt` command.
    echo -e "ERROR    | Terraform fmt output:"
    echo -e $output
    pr_comment="<details><summary>Show Output</summary>
<p>
$output
</p>
</details>"
fi

# Exit Code: 3
# Meaning: One or more files are incorrectly formatted.
# Actions: Iterate over all files and build diff-based pull request comment.
if [[ $exit_code -eq 3 ]]; then
    echo "ERROR    | Terraform file(s) are incorrectly formatted."
    # Add output of `terraform fmt` command.
    echo -e "ERROR    | Terraform fmt output:"
    echo -e $output
    all_files_diff=""
    output=""
    files=$(terraform fmt -check -write=false -list ${recursive})
    for file in $files; do
        this_file_diff=$(terraform fmt -no-color -write=false -diff "$file")
        all_files_diff="$all_files_diff
<details><summary><code>$file</code></summary>
<p>

\`\`\`diff
$this_file_diff
\`\`\`

</p>
</details>"
        output="$output

$this_file_diff"
    done
    echo -e "ERROR    | Terraform fmt output:"
    echo -e "$output"
    pr_comment="$all_files_diff"
fi

PULL_REQUEST_COMMENT "$pr_comment"

exit $exit_code
