# Terraform Format (fmt) action

This is one of a suite of terraform related actions.

This action uses the `terraform fmt` command to check that all terraform files in a terraform configuration directory are in the canonical format.
This can be used to check that files are properly formatted before merging.

If any files are not correctly formatted, the GitHub Action job failed.

A comment will be added to the pull request in case of error. If it is related to the `terraform fmt` command, the comment will contain the output of the command.

## Requirements

* This GitHub Actions does not install `terraform`, so you have to install them in advanced.

  ```yaml
  - name: Setup Terraform
    uses: hashicorp/setup-terraform@v2
    with:
      terraform_wrapper: false
  ```

## Inputs

* `path`

  By default, fmt scans the current directory for configuration files. If you provide a directory for the `path` argument, then fmt will scan that directory instead. 
 
  - Type: string
  - Optional
  - Default: The current directory

  ```yaml
  with:
    path: ./modules
  ```

* `recursive`

  Process files in subdirectories. By default, all subdirectories are process.

  - Type: boolean
  - Optional
  - Default: true

  ```yaml
  with:
    recursive: false
  ```

## Environment Variables

* `GITHUB_TOKEN`

  The GitHub authorization token to use to add a comment to a PR. 
  The token provided by GitHub Actions can be used - it can be passed by
  using the `${{ secrets.GITHUB_TOKEN }}` expression, e.g.

  ```yaml
  env:
    GITHUB_TOKEN: ${{ secrets.GITHUB_TOKEN }}
  ```

  The token provided by GitHub Actions will work with the default permissions.
  The minimum permissions are `pull-requests: write`.
  It will also likely need `contents: read` so the job can checkout the repo.

## Example usage

This example workflow runs on pull request and fails if any of the terraform files are not formatted correctly.

```yaml
name: Check terraform file formatting

on:
  pull_request:

permissions:
  contents: read
  pull-requests: write

jobs:
  TerraformFormat:
    runs-on: ubuntu-latest
    name: Check terraform file formatting
    env:
      GITHUB_TOKEN: ${{ secrets.GITHUB_TOKEN }}
    steps:
      - name: Setup Terraform
        uses: hashicorp/setup-terraform@v2
        with:
          terraform_wrapper: false

      - name: Checkout
        uses: actions/checkout@v3

      - name: terraform fmt
        id: fmt
        uses: benyboy84/GitHubAction_terraform-fmt@v1
        with:
          path: ./modules
          recursive: false
```

## Screenshots

![fmt](images/fmt-output.png)
