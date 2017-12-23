module "origin_label" {
  source     = "git::https://github.com/cloudposse/terraform-null-label.git?ref=tags/0.2.1"
  namespace  = "${var.namespace}"
  stage      = "${var.stage}"
  name       = "${var.name}"
  delimiter  = "${var.delimiter}"
  attributes = ["origin"]
  tags       = "${var.tags}"
}

resource "aws_cloudfront_origin_access_identity" "default" {
  comment = "${module.distribution_label.id}"
}

data "aws_iam_policy_document" "origin" {
  statement {
    actions   = ["s3:GetObject"]
    resources = ["arn:aws:s3:::$${bucket_name}$${origin_path}*"]

    principals {
      type        = "AWS"
      identifiers = ["${aws_cloudfront_origin_access_identity.default.iam_arn}"]
    }
  }

  statement {
    actions   = ["s3:ListBucket"]
    resources = ["arn:aws:s3:::$${bucket_name}"]

    principals {
      type        = "AWS"
      identifiers = ["${aws_cloudfront_origin_access_identity.default.iam_arn}"]
    }
  }
}

data "template_file" "default" {
  template = "${data.aws_iam_policy_document.origin.json}"

  vars {
    origin_path = "${coalesce(var.origin_path, "/")}"
    bucket_name = "${null_resource.default.triggers.bucket}"
  }
}

resource "aws_s3_bucket_policy" "default" {
  bucket = "${null_resource.default.triggers.bucket}"
  policy = "${data.template_file.default.rendered}"
}

resource "aws_s3_bucket" "origin" {
  count  = "${signum(length(var.origin_bucket)) == 1 ? 0 : 1}"
  bucket = "${module.origin_label.id}"
  acl    = "private"
  tags   = "${module.origin_label.tags}"
  force_destroy = "${var.origin_force_destroy}"

  cors_rule {
    allowed_headers = "${var.cors_allowed_headers}"
    allowed_methods = "${var.cors_allowed_methods}"
    allowed_origins = "${sort(distinct(compact(concat(var.cors_allowed_origins, var.aliases))))}"
    expose_headers  = "${var.cors_expose_headers}"
    max_age_seconds = "${var.cors_max_age_seconds}"
  }
}

module "logs" {
  source                   = "git::https://github.com/cloudposse/terraform-aws-s3-log-storage.git?ref=tags/0.1.2"
  namespace                = "${var.namespace}"
  stage                    = "${var.stage}"
  name                     = "${var.name}"
  delimiter                = "${var.delimiter}"
  attributes               = ["logs"]
  tags                     = "${var.tags}"
  prefix                   = "${var.log_prefix}"
  standard_transition_days = "${var.log_standard_transition_days}"
  glacier_transition_days  = "${var.log_glacier_transition_days}"
  expiration_days          = "${var.log_expiration_days}"
}

module "distribution_label" {
  source    = "git::https://github.com/cloudposse/terraform-null-label.git?ref=tags/0.2.1"
  namespace = "${var.namespace}"
  stage     = "${var.stage}"
  name      = "${var.name}"
  delimiter = "${var.delimiter}"
  tags      = "${var.tags}"
}

resource "null_resource" "default" {
  triggers {
    bucket             = "${element(compact(concat(list(var.origin_bucket), aws_s3_bucket.origin.*.bucket)), 0)}"
    bucket_name        = "${element(compact(concat(list(var.origin_bucket), aws_s3_bucket.origin.*.id)), 0)}"
    bucket_domain_name = "${format(var.bucket_domain_format, element(compact(concat(list(var.origin_bucket), aws_s3_bucket.origin.*.bucket)), 0))}"
  }

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_cloudfront_distribution" "default" {
  enabled             = "${var.enabled}"
  is_ipv6_enabled     = "${var.is_ipv6_enabled}"
  comment             = "${var.comment}"
  default_root_object = "${var.default_root_object}"
  price_class         = "${var.price_class}"
  depends_on          = ["aws_s3_bucket.origin"]

  logging_config = {
    include_cookies = "${var.log_include_cookies}"
    bucket          = "${module.logs.bucket_domain_name}"
    prefix          = "${var.log_prefix}"
  }

  aliases = ["${var.aliases}"]

  origin {
    domain_name = "${null_resource.default.triggers.bucket_domain_name}"
    origin_id   = "${module.distribution_label.id}"
    origin_path = "${var.origin_path}"

    s3_origin_config {
      origin_access_identity = "${aws_cloudfront_origin_access_identity.default.cloudfront_access_identity_path}"
    }
  }

  origin {
    domain_name = "${var.services_domain}"
    origin_id = "ServicesOrigin"

    custom_origin_config {
      http_port = 80
      https_port = 443
      origin_protocol_policy = "match-viewer"
      origin_ssl_protocols = ["SSLv3"]
    }
  }

  viewer_certificate {
    acm_certificate_arn            = "${var.acm_certificate_arn}"
    ssl_support_method             = "sni-only"
    minimum_protocol_version       = "TLSv1"
    cloudfront_default_certificate = true
  }

  default_cache_behavior {
    allowed_methods  = "${var.allowed_methods}"
    cached_methods   = "${var.cached_methods}"
    target_origin_id = "${module.distribution_label.id}"
    compress         = "${var.compress}"

    forwarded_values {
      query_string = "${var.forward_query_string}"

      cookies {
        forward = "${var.forward_cookies}"
      }
    }

    viewer_protocol_policy = "${var.viewer_protocol_policy}"
    default_ttl            = "${var.default_ttl}"
    min_ttl                = "${var.min_ttl}"
    max_ttl                = "${var.max_ttl}"
  }

  cache_behavior {
    allowed_methods       = "${var.allowed_methods}"
    cached_methods        = "${var.cached_methods}"
    target_origin_id      = "ServicesOrigin"
    path_pattern          = "services/*"
    compress              = "${var.compress}"

    forwarded_values {
      query_string        = "${var.forward_query_string}"

      cookies {
        forward           = "${var.forward_cookies}"
      }
    }

    viewer_protocol_policy = "${var.viewer_protocol_policy}"
    default_ttl           = "${var.default_ttl}"
    min_ttl               = "${var.min_ttl}"
    max_ttl               = "${var.max_ttl}"
  }

  restrictions {
    geo_restriction {
      restriction_type = "${var.geo_restriction_type}"
      locations        = "${var.geo_restriction_locations}"
    }
  }

  custom_error_response {
    error_code = 403
    response_code = 200
    response_page_path = "/index.html"
  }

  custom_error_response {
    error_code = 404
    response_code = 200
    response_page_path = "/index.html"
  }

  tags = "${module.distribution_label.tags}"
}

module "dns" {
  source           = "git::https://github.com/cloudposse/terraform-aws-route53-alias.git?ref=tags/0.2.2"
  aliases          = "${var.aliases}"
  parent_zone_id   = "${var.parent_zone_id}"
  parent_zone_name = "${var.parent_zone_name}"
  target_dns_name  = "${aws_cloudfront_distribution.default.domain_name}"
  target_zone_id   = "${aws_cloudfront_distribution.default.hosted_zone_id}"
}
