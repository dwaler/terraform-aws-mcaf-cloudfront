locals {
  redirect_uri = "https://${aws_cloudfront_distribution.default.domain_name}/_callback"
  ssm_prefix   = "/cloudfront-config/${aws_cloudfront_distribution.default.id}"
  assume_role  = var.assume_role ? { create : true } : {}
  assume_role_arn = format(
    "arn:aws:iam::%s:role/%s",
    data.aws_caller_identity.current.account_id,
    split("/", data.aws_caller_identity.current.arn)[1]
  )
}

provider "aws" {
  alias  = "ssm"
  region = "eu-west-1"

  dynamic assume_role {
    for_each = local.assume_role

    content {
      role_arn = local.assume_role_arn
    }
  }
}

resource "aws_kms_key" "default" {
  provider                = "aws.ssm"
  description             = "KMS key used for encrypting cloudfront SSM parameters"
  is_enabled              = true
  enable_key_rotation     = false
  tags                    = var.tags
}

resource "aws_kms_alias" "default" {
  provider      = "aws.ssm"
  name          = "alias/cloudfront-ssm-${aws_cloudfront_distribution.default.id}"
  target_key_id = aws_kms_key.default.key_id
}


data "aws_iam_policy_document" "authentication" {
  statement {
    actions = [
      "s3:ListBucket"
    ]
    resources = [
      module.origin_bucket.arn
    ]
  }

  statement {
    actions = [
      "s3:GetObject"
    ]
    resources = [
      "${module.origin_bucket.arn}${var.origin_path}/*"
    ]
  }

  statement {
    actions = [
      "kms:Decrypt"
    ]
    resources = [
      aws_kms_key.default.arn
    ]
  }

  statement {
    actions = [
      "ssm:GetParameters"
    ]
    resources = [
      "arn:aws:ssm:*:*:parameter/cloudfront-config/${aws_cloudfront_distribution.default.id}/*"
    ]
  }
}

module "authentication" {
  source      = "github.com/schubergphilis/terraform-aws-mcaf-lambda?ref=v0.1.3"
  name        = "${var.name}-authentication"
  assume_role = true
  filename    = "${path.module}/auth_lambda/artifacts/index.zip"
  runtime     = "nodejs10.x"
  handler     = "index.handler"
  policy      = data.aws_iam_policy_document.authentication.json
  publish     = true
  region      = "us-east-1"
  tags        = var.tags
}

resource "okta_app_oauth" "default" {
  count                      = var.authentication ? 1 : 0
  label                      = var.okta_app_name
  status                     = "ACTIVE"
  type                       = "web"
  grant_types                = ["authorization_code", "implicit"]
  login_uri                  = "https://${aws_cloudfront_distribution.default.domain_name}/"
  redirect_uris              = [local.redirect_uri]
  response_types             = ["id_token", "code"]
  token_endpoint_auth_method = "client_secret_jwt"

  lifecycle {
    ignore_changes = ["users", "groups"]
  }
}

resource "tls_private_key" "default" {
  count     = var.authentication ? 1 : 0
  algorithm = "RSA"
}

resource "aws_ssm_parameter" "client_id" {
  provider = "aws.ssm"
  count    = var.authentication ? 1 : 0
  name     = "${local.ssm_prefix}/client_id"
  type     = "SecureString"
  value    = okta_app_oauth.default[0].client_id
  key_id   = aws_kms_key.default.id
}

resource "aws_ssm_parameter" "client_secret" {
  provider = "aws.ssm"
  count    = var.authentication ? 1 : 0
  name     = "${local.ssm_prefix}/client_secret"
  type     = "SecureString"
  value    = okta_app_oauth.default[0].client_secret
  key_id   = aws_kms_key.default.id
}

resource "aws_ssm_parameter" "okta_org_name" {
  provider = "aws.ssm"
  count    = var.authentication ? 1 : 0
  name     = "${local.ssm_prefix}/okta_org_name"
  type     = "String"
  value    = var.okta_org_name
}

resource "aws_ssm_parameter" "private_key" {
  provider = "aws.ssm"
  count    = var.authentication ? 1 : 0
  name     = "${local.ssm_prefix}/private_key"
  type     = "SecureString"
  value    = tls_private_key.default[0].private_key_pem
  key_id   = aws_kms_key.default.id
}

resource "aws_ssm_parameter" "public_key" {
  provider = "aws.ssm"
  count    = var.authentication ? 1 : 0
  name     = "${local.ssm_prefix}/public_key"
  type     = "SecureString"
  value    = tls_private_key.default[0].public_key_pem
  key_id   = aws_kms_key.default.id
}

resource "aws_ssm_parameter" "redirect_uri" {
  provider = "aws.ssm"
  count    = var.authentication ? 1 : 0
  name     = "${local.ssm_prefix}/redirect_uri"
  type     = "String"
  value    = local.redirect_uri
}
