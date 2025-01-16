output "force_versioning" {
  description = "The value of the `force_versioning` input variable."
  value       = var.force_versioning
}

output "checked" {
  description = "Whether the module consistency check is complete. Used for forcing other resources/modules to wait for this check to complete before running."
  # This ternary just forces the response to wait for the lock file to be written
  value = module.assert_no_unversioned_modules.checked
}
