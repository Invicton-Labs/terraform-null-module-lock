output "consistent" {
  description = "Whether the modules are consistent with the lock file versions."
  value       = local_file.lock.content_base64sha256 != null
}
