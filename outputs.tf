output "force_versioning" {
  description = "The value of the `force_versioning` input variable."
  value       = var.force_versioning
}

output "consistent" {
  description = "Whether the modules are consistent with the lock file versions."
  value       = local_file.lock.content_base64sha256 != ""
}
