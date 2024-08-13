locals {
  # Combine all lifecycle rules into a single list
  combined_lifecycle_configuration_rules = flatten([
    for rules in [
      local.s3_dradis_backup_rules,
      local.s3_nextcloud_backup_rules
      # Add more lifecycle rules if needed
    ] : rules
  ])
  
  # Normalize the combined lifecycle rules
  normalized_lifecycle_configuration_rules = [for rule in local.combined_lifecycle_configuration_rules : {
    enabled = rule.enabled
    id      = rule.id

    abort_incomplete_multipart_upload_days = rule.abort_incomplete_multipart_upload_days

    filter_prefix_only = (try(rule.filter_and.object_size_greater_than, null) == null &&
      try(rule.filter_and.object_size_less_than, null) == null &&
      try(length(rule.filter_and.tags), 0) == 0 &&
    try(length(rule.filter_and.prefix), 0) > 0) ? rule.filter_and.prefix : null

    filter_and = (try(rule.filter_and.object_size_greater_than, null) == null &&
      try(rule.filter_and.object_size_less_than, null) == null &&
      try(length(rule.filter_and.tags), 0) == 0) ? null : {
      object_size_greater_than = try(rule.filter_and.object_size_greater_than, null)
      object_size_less_than    = try(rule.filter_and.object_size_less_than, null)
      prefix                   = try(length(rule.filter_and.prefix), 0) == 0 ? null : rule.filter_and.prefix
      tags                     = try(length(rule.filter_and.tags), 0) == 0 ? {} : rule.filter_and.tags
    }

    expiration = (try(rule.expiration.date, null) == null &&
      try(rule.expiration.days, null) == null &&
      try(rule.expiration.expired_object_delete_marker, null) == null) ? null : {
      date = try(rule.expiration.date, null)
      days = try(rule.expiration.days, null)

      expired_object_delete_marker = try(rule.expiration.expired_object_delete_marker, null)
    }
    noncurrent_version_expiration = (try(rule.noncurrent_version_expiration.noncurrent_days, null) == null &&
      try(rule.noncurrent_version_expiration.newer_noncurrent_versions, null) == null) ? null : {
      newer_noncurrent_versions = try(rule.noncurrent_version_expiration.newer_noncurrent_versions, null)
      noncurrent_days           = try(rule.noncurrent_version_expiration.noncurrent_days, null)
    }
    transition = rule.transition == null ? [] : [for t in rule.transition : {
      date          = try(t.date, null)
      days          = try(t.days, null)
      storage_class = t.storage_class
    } if try(t.date, null) != null || try(t.days, null) != null]
    noncurrent_version_transition = rule.noncurrent_version_transition == null ? [] : [
      for t in rule.noncurrent_version_transition :
      {
        newer_noncurrent_versions = try(t.newer_noncurrent_versions, null)
        noncurrent_days           = try(t.noncurrent_days, null)
        storage_class             = t.storage_class
      } if try(t.newer_noncurrent_versions, null) != null || try(t.noncurrent_days, null) != null
    ]
  }]

  # Backwards compatibility: translate old `lifecycle_rules` variable to new format
  lifecycle_rules = var.lifecycle_rules == null ? [] : var.lifecycle_rules
  normalized_lifecycle_rules = [for i, rule in local.lifecycle_rules : {
    enabled = rule.enabled
    id      = try(var.lifecycle_rule_ids[i], "rule-${i + 1}")

    abort_incomplete_multipart_upload_days = rule.abort_incomplete_multipart_upload_days # number

    filter_prefix_only = try(length(rule.prefix), 0) > 0 && try(length(rule.tags), 0) == 0 ? rule.prefix : null
    filter_and = try(length(rule.tags), 0) == 0 ? null : {
      object_size_greater_than = null                                   # integer >= 0
      object_size_less_than    = null                                   # integer >= 1
      prefix                   = rule.prefix == "" ? null : rule.prefix # string
      tags                     = rule.tags == null ? {} : rule.tags     # map(string)
    }
    # We use "!= true" because it covers !null as well as !false, and allows the "null" option to be on the same line.
    expiration = rule.enable_current_object_expiration != true ? null : {
      date                         = null                 # string
      days                         = rule.expiration_days # integer > 0
      expired_object_delete_marker = null                 # bool
    }
    noncurrent_version_expiration = rule.enable_noncurrent_version_expiration != true ? null : {
      newer_noncurrent_versions = null                                    # integer > 0
      noncurrent_days           = rule.noncurrent_version_expiration_days # integer >= 0
    }
    transition = concat(
      rule.enable_standard_ia_transition != true ? [] :
      [{
        date          = null                          # string
        days          = rule.standard_transition_days # integer >= 0
        storage_class = "STANDARD_IA"
      }],
      rule.enable_glacier_transition != true ? [] :
      [{
        date          = null                         # string
        days          = rule.glacier_transition_days # integer >= 0
        storage_class = "GLACIER"
      }],
      rule.enable_deeparchive_transition != true ? [] :
      [{
        date          = null                             # string
        days          = rule.deeparchive_transition_days # integer >= 0
        storage_class = "DEEP_ARCHIVE"
      }],
    )
    noncurrent_version_transition = concat(
      # In the old `lifecycle_rules` variable, `enable_glacier_transition`
      # enabled the transition for both current and non-current version.
      rule.enable_glacier_transition != true ? [] :
      [{
        newer_noncurrent_versions = null                                            # integer >= 0
        noncurrent_days           = rule.noncurrent_version_glacier_transition_days # integer >= 0
        storage_class             = "GLACIER"
      }],
      # In the old `lifecycle_rules` variable, `enable_deeparchive_transition`
      # enabled the transition for both current and non-current version.
      rule.enable_deeparchive_transition != true ? [] :
      [{
        newer_noncurrent_versions = null                                                # integer >= 0
        noncurrent_days           = rule.noncurrent_version_deeparchive_transition_days # integer >= 0
        storage_class             = "DEEP_ARCHIVE"
      }],
    )
  }]

  lc_rules = concat(local.normalized_lifecycle_rules, local.normalized_lifecycle_configuration_rules)
}


resource "aws_s3_bucket_lifecycle_configuration" "default" {
  count  = local.enabled && length(local.normalized_lifecycle_configuration_rules) > 0 ? 1 : 0
  bucket = local.bucket_id

  dynamic "rule" {
    for_each = local.normalized_lifecycle_configuration_rules

    content {
      id     = rule.value.id
      status = rule.value.enabled == true ? "Enabled" : "Disabled"

      dynamic "filter" {
        for_each = rule.value.filter_prefix_only == null && rule.value.filter_and == null ? ["empty"] : []
        content {}
      }

      dynamic "filter" {
        for_each = rule.value.filter_prefix_only == null ? [] : ["prefix"]
        content {
          prefix = rule.value.filter_prefix_only
        }
      }

      dynamic "filter" {
        for_each = rule.value.filter_and == null ? [] : ["and"]
        content {
          and {
            object_size_greater_than = rule.value.filter_and.object_size_greater_than
            object_size_less_than    = rule.value.filter_and.object_size_less_than
            prefix                   = rule.value.filter_and.prefix
            tags                     = rule.value.filter_and.tags
          }
        }
      }

      dynamic "abort_incomplete_multipart_upload" {
        for_each = rule.value.abort_incomplete_multipart_upload_days == null ? [] : [1]
        content {
          days_after_initiation = rule.value.abort_incomplete_multipart_upload_days
        }
      }

      dynamic "expiration" {
        for_each = rule.value.expiration == null ? [] : [rule.value.expiration]
        content {
          date                         = expiration.value.date
          days                         = expiration.value.days
          expired_object_delete_marker = expiration.value.expired_object_delete_marker
        }
      }

      dynamic "noncurrent_version_expiration" {
        for_each = rule.value.noncurrent_version_expiration == null ? [] : [rule.value.noncurrent_version_expiration]
        iterator = expiration
        content {
          newer_noncurrent_versions = expiration.value.newer_noncurrent_versions
          noncurrent_days           = expiration.value.noncurrent_days
        }
      }

      dynamic "transition" {
        for_each = rule.value.transition

        content {
          date          = transition.value.date
          days          = transition.value.days
          storage_class = transition.value.storage_class
        }
      }

      dynamic "noncurrent_version_transition" {
        for_each = rule.value.noncurrent_version_transition
        iterator = transition
        content {
          newer_noncurrent_versions = transition.value.newer_noncurrent_versions
          noncurrent_days           = transition.value.noncurrent_days
          storage_class             = transition.value.storage_class
        }
      }
    }
  }

  depends_on = [
    # versioning must be set before lifecycle configuration
    aws_s3_bucket_versioning.default
  ]
}

locals {
  s3_dradis_backup_rules = local.s3_dradis_backup_rules
  s3_nextcloud_backup_rules = local.s3_nextcloud_backup_rules
  # Add more sets if needed
}
