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

# Optional inputs

# Validate input comment.
if [[ ! "$INPUT_COMMENT" =~ ^(true|false)$ ]]; then
    echo "ERROR    | Unsupported command \"$INPUT_COMMENT\" for input \"comment\". Valid values are \"true\" or \"false\"."
    exit 1
fi

# Validate input target.
target=""
if [[ -n "$INPUT_TARGET" ]]; then
    if [[ -d "$INPUT_TARGET" || -f "$INPUT_TARGET" ]]; then
        target=$INPUT_TARGET
    else
        exit_code=1
        echo "ERROR    | Target does not exist: \"$INPUT_TARGET\"."
        exit 1
    fi
fi

# Validate input check.
if [[ ! "$INPUT_CHECK" =~ ^(true|false)$ ]]; then
    echo "ERROR    | Unsupported command \"$INPUT_CHECK\" for input \"check\". Valid values are \"true\" or \"false\"."
    exit 1
fi

# Validate input recursive.
recursive=""
if [[ ! "$INPUT_RECURSIVE" =~ ^(true|false)$ ]]; then
    echo "ERROR    | Unsupported command \"$INPUT_RECURSIVE\" for input \"recursive\". Valid values are \"true\" or \"false\"."
    exit 1
fi
if [[ "$INPUT_RECURSIVE" == true ]]; then
    recursive="-recursive"
fi

# Detect terraform version
version=$(terraform version -json | jq -r '.terraform_version' 2>/dev/null || terraform version | grep 'Terraform v' | sed 's/Terraform v//')
if [[ -z $version  ]]; then
    echo "ERROR    | Terraform not detected."
    exit 1
else
    echo "INFO     | Using terraform version $version."
fi

# Gather the output of `terraform fmt`.
output=$(terraform fmt -list=false -check ${recursive} ${target})
exit_code=${?}

# Output informations for future use.
echo "exitcode=$exit_code" >> $GITHUB_OUTPUT
echo "output=$output" >> $GITHUB_OUTPUT

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
    pr_comment="### Terraform Format Failed
<details><summary>Show Output</summary>
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

    if [[ $INPUT_CHECK == false ]]; then
        # Add output of `terraform fmt` command.
        echo -e "WARNING  | Terraform fmt output:"
        echo -e "$output"
        echo "INFO     | Terraform file(s) are being formatted."
        # Gather the output of `terraform fmt`.
        format_output=$(terraform fmt ${recursive} ${target} -write=true)
        format_exit_code=${?}
        if [[ $format_exit_code -eq 0 ]]; then
            echo "INFO     | Terraform Format Succeeded."
            pr_comment="### Terraform Format Succeeded
The following files have been formatted, make sure to perform a 'git pull' to update your local repository.
$all_files_diff"
        elif [[ $format_exit_code -eq 1 || $format_exit_code -eq 2 ]]; then
            if [[ $format_exit_code -eq 2 ]]; then
                echo "ERROR    | Failed to parse terraform file(s)."
            else
                echo "ERROR    | Malformed terraform CLI command."
            fi
            pr_comment="### Terraform Format Failed
<details><summary>Show Output</summary>
<p>
$format_output
</p>
</details>"
        fi
    else
        pr_comment="### Terraform Format Failed
$all_files_diff"
    fi
fi

if [[ $INPUT_COMMENT == true ]]; then
    #if [[ "$GITHUB_EVENT_NAME" != "push" && "$GITHUB_EVENT_NAME" != "pull_request" && "$GITHUB_EVENT_NAME" != "issue_comment" && "$GITHUB_EVENT_NAME" != "pull_request_review_comment" && "$GITHUB_EVENT_NAME" != "pull_request_target" && "$GITHUB_EVENT_NAME" != "pull_request_review" ]]; then
    if [[ "$GITHUB_EVENT_NAME" != "pull_request" && "$GITHUB_EVENT_NAME" != "issue_comment" ]]; then
        echo "WARNING  | $GITHUB_EVENT_NAME event does not relate to a pull request."
    else
        if [[ -z GITHUB_TOKEN ]]; then
            echo "WARNING  | GITHUB_TOKEN not defined. Pull request comment is not possible without a GitHub token."
        else
            # Look for an existing pull request comment and delete
            echo "INFO     | Looking for an existing pull request comment."
            accept_header="Accept: application/vnd.github.v3+json"
            auth_header="Authorization: token $GITHUB_TOKEN"
            content_header="Content-Type: application/json"
            if [[ "$GITHUB_EVENT_NAME" == "issue_comment" ]]; then
                pr_comments_url=$(jq -r ".issue.comments_url" "$GITHUB_EVENT_PATH")
            else
                pr_comments_url=$(jq -r ".pull_request.comments_url" "$GITHUB_EVENT_PATH")
            fi
            pr_comment_uri=$(jq -r ".repository.issue_comment_url" "$GITHUB_EVENT_PATH" | sed "s|{/number}||g")
            pr_comment_id=$(curl -sS -H "$auth_header" -H "$accept_header" -L "$pr_comments_url" | jq '.[] | select(.body|test ("### Terraform Format")) | .id')
            if [ "$pr_comment_id" ]; then
                if [[ $(IS_ARRAY $pr_comment_id)  -ne 0 ]]; then
                    echo "INFO     | Found existing pull request comment: $pr_comment_id. Deleting."
                    pr_comment_url="$pr_comment_uri/$pr_comment_id"
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
                body="$pr_comment"
                pr_payload=$(echo '{}' | jq --arg body "$body" '.body = $body')
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
fi

# Exit with the result based on the `check`property
if [[ $INPUT_CHECK == true ]]; then
    exit $exit_code
else
    if [[ $exit_code -eq 3 ]]; then
        exit $format_exit_code
    else 
        exit $exit_code
    fi
fi
