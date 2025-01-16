locals {
  # Used to find any other instances of the same module.
  # Note that there's a file in this module with this
  # as its name.
  module_id = "01946bda-d8d3-7873-ac6f-e2c4151792a8"

  # Clean it up and ensure it doesn't end with a slash.
  root_dir = trimsuffix(trimsuffix(path.root, "/"), "\\")
  # Prepare the paths to the three files we care about
  modules_json_file = "${local.root_dir}/.terraform/modules/modules.json"
  lock_file         = "${local.root_dir}/.terraform.modules.lock.json"

  # Check whether these files exist
  modules_exists = fileexists(local.modules_json_file)
  lock_exists    = fileexists(local.lock_file)

  # Load the module lock file, or default to an empty
  # map if the file doesn't exist
  module_lock = local.lock_exists ? jsondecode(file(local.lock_file)) : {}
}

# Ensure that the modules file exists. It should ALWAYS exist, because this module
# was initialized, and therefore there's at least one module.
module "assert_modules_exists" {
  source        = "github.com/Invicton-Labs/terraform-null-assertion?ref=30d308e4dab7f1e083abb4e6293b2865fccfffb5" // Corresponds to v0.2.6
  condition     = local.modules_exists
  error_message = "There is no modules config file in the expected location (${local.modules_json_file})."
}

locals {
  # Get the path of this module relative to the root
  this_module_path = trimprefix(path.module, "${trimsuffix(trimsuffix(path.root, "/"), "\\")}/")

  all_modules = module.assert_modules_exists.checked ? {
    # Loop through all modules that are installed/used
    for k, v in jsondecode(file(local.modules_json_file))["Modules"] :
    (v.Key) => {
      source    = v.Source
      directory = v.Dir
      # It's a local module if the abspath of the source matches
      # the abspath of the dir it's accessed from.
      is_local = try(abspath(v.Source), null) == abspath(v.Dir)
      # The version is the specified version if there is one, or the ref tag if there is one
      version = lookup(v, "Version", (
        startswith(lower(v.Source), "git::") || startswith(lower(v.Source), "hg::") ? (
          # If it's git or mercurial, it can have a `ref` query parameter to specify a branch/version.
          # See if there are any query parameters by splitting on `?` and checking if there are at least 2 segments.
          length(split("?", v.Source)) > 1 ? (
            # `one` will get the first element if it exists, otherwise returns null
            one([
              # Check each query parameter
              for qp in split("&", split("?", v.Source)[1]) :
              # Take the value after the `=` as the ref value
              split("=", qp)[1]
              # Only consider it if there query parameter has a value and the parameter's name is `ref`
              if length(split("=", qp)) > 1 && lower(split("=", qp)[0]) == "ref"
            ])
          ) : null
        ) : null
        )
      )
    }
    # Filter on empty key because that appears to refer to the root.
    if v.Key != ""
  } : null

  # Add the hash to all modules that can be versioned
  all_modules_with_hashes = {
    for k, v in local.all_modules :
    k => merge(v, {
      # Create a complete hash of all files
      hash = !v.is_local && v.version != null ? base64sha512(join(";", [
        for filename in fileset(v.directory, "**") :
        "${base64sha512(filename)}:${filebase64sha512("${v.directory}/${filename}")}"
      ])) : null
    })
  }

  # Create a list of module keys that aren't versioned, but could be
  unversioned_modules = var.force_versioning ? [
    for k, v in local.all_modules_with_hashes :
    k
    if v.version == null && !v.is_local
  ] : []

  # Find any modules where the hash doesn't match the locked hash
  mismatched_modules = local.lock_exists ? {
    for k, v in local.all_modules_with_hashes :
    k => v
    # Add it as a mismatch if 
    #   (a) it's versioned
    if v.version != null ? (
      #   (b) it's not local
      !v.is_local ? (
        #   (c) the lock file knows of this module, 
        lookup(local.module_lock, k, null) != null ? (
          #   (d) the version matches, 
          v.version == local.module_lock[k].version ? (
            #   (e) the source matches, and 
            v.source == local.module_lock[k].source ? (
              #   (f) the hash does NOT match
          v.hash != local.module_lock[k].hash) : false) : false
        ) : false
      ) : false
    ) : false
  } : {}

  # Find all other instances of this module. We do that by
  # searching each known module for the ID file. This method
  # ensures that we find others even if they're a different 
  # version or different source.
  module_id_instances = [
    for k, v in local.all_modules_with_hashes :
    k
    if length(fileset("${path.root}/${v.directory}", local.module_id)) > 0
  ]
}

output "debug" {
  value = {
    all_modules_with_hashes = local.all_modules_with_hashes
  }
}

# Assert that there's only one copy of this module in the configuration.
module "assert_single_use" {
  source        = "github.com/Invicton-Labs/terraform-null-assertion?ref=30d308e4dab7f1e083abb4e6293b2865fccfffb5"
  condition     = length(local.module_id_instances) == 1
  error_message = "Only a single instance of the Invicton-Labs/module-lock/null module can exist in a Terraform configuration (found ${length(local.module_id_instances)}). All instances: ${join(", ", local.module_id_instances)}. If all but one have already been removed, try deleting the ${local.modules_json_file} file and re-initialize."
}

# Assert that the module hashes match the lock versions
module "assert_module_hashes_match" {
  source        = "github.com/Invicton-Labs/terraform-null-assertion?ref=30d308e4dab7f1e083abb4e6293b2865fccfffb5"
  depends_on    = [module.assert_single_use]
  condition     = module.assert_single_use.checked && length(local.mismatched_modules) == 0
  error_message = "SECURITY RISK!!! The following ${length(local.mismatched_modules) > 1 ? "modules have different hashes, even though the sources/versions haven't changed" : "module has a different hash, even though the source/version hasn't changed"}: ${join(", ", [for k, v in local.mismatched_modules : k])}"
}

# If desired, assert that there are no unversioned modules
module "assert_no_unversioned_modules" {
  source     = "github.com/Invicton-Labs/terraform-null-assertion?ref=30d308e4dab7f1e083abb4e6293b2865fccfffb5"
  depends_on = [module.assert_module_hashes_match]
  # The list of unversioned modules is empty if var.force_versioning is false
  condition     = length(local.unversioned_modules) == 0
  error_message = "SECURITY RISK!!! The following ${length(local.unversioned_modules) > 1 ? "modules are not pinned to specific versions or refs, but they should be" : "module is not pinned to a specific version or ref, but it should be"}: ${join(", ", [for k in local.unversioned_modules : k])}"
}

# Create/update the lock file
resource "local_file" "lock" {
  # Mark it sensitive so it doesn't clog the output
  content = sensitive(jsonencode({
    for k, v in local.all_modules_with_hashes :
    k => {
      source  = v.source
      version = v.version
      hash    = v.hash
    }
    if v.hash != null
  }))
  # Force a dependency on the module check, so we don't overwrite the file
  # with the mismatched values if there are mismatches.
  filename = module.assert_no_unversioned_modules.checked ? local.lock_file : ""
}
