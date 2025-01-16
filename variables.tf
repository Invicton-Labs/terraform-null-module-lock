variable "force_versioning" {
  description = "If `true`, the module will throw an error if there are any non-local modules that don't have a version or `ref` specified. If `false`, the module will only check versioned modules for consistency."
  type        = bool
  default     = true
  nullable    = false
}
