# tflint configuration.
#
#   tflint --init
#   tflint --recursive

config {
  call_module_type = "local"
  force            = false
}

plugin "terraform" {
  enabled = true
  preset  = "recommended"
}

plugin "aws" {
  enabled = true
  version = "0.46.0"
  source  = "github.com/terraform-linters/tflint-ruleset-aws"
}

# Every variable and output carries a description. Generated documentation is
# only as good as these, so the linter enforces them rather than relying on
# review to catch an omission.
rule "terraform_documented_variables" {
  enabled = true
}

rule "terraform_documented_outputs" {
  enabled = true
}

rule "terraform_typed_variables" {
  enabled = true
}

rule "terraform_naming_convention" {
  enabled = true
  format  = "snake_case"
}

rule "terraform_unused_declarations" {
  enabled = true
}

rule "terraform_deprecated_interpolation" {
  enabled = true
}

rule "terraform_deprecated_index" {
  enabled = true
}

# Module sources must be pinned. An unpinned source means infrastructure can
# change without a commit in this repository.
rule "terraform_module_pinned_source" {
  enabled = true
  style   = "flexible"
}

rule "terraform_required_providers" {
  enabled = true
}

rule "terraform_required_version" {
  enabled = true
}
