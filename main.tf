locals {
  # Clean it up and ensure it doesn't end with a slash.
  working_dir = trimsuffix(trimsuffix(path.root, "/"), "\"")
  # Prepare the paths to the three files we care about
  modules_json_file = "${local.working_dir}/.terraform/modules/modules.json"
  lock_file         = "${local.working_dir}/.terraform.modules.lock.json"

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
  source        = "Invicton-Labs/assertion/null"
  version       = "~>0.2.4"
  condition     = local.modules_exists
  error_message = "There is no modules config file in the expected location (${local.modules_json_file})."
}

locals {
  # Get the path of this module relative to the root
  this_module_path = trimprefix(path.module, "${trimsuffix(trimsuffix(path.root, "/"), "\\")}/")

  # Prepare a map of modules
  # This ternary just forces a wait on the assertion that the state file exists.
  modules = module.assert_modules_exists.checked ? {
    # Loop through all modules that are installed/used
    for k, v in jsondecode(file(local.modules_json_file))["Modules"] :
    # For each one, use the existing module data from the modules.json file,
    # but also add additional info.
    v["Key"] => {
      source    = v.Source
      version   = lookup(v, "Version", null)
      directory = v.Dir
      files = {
        # Create a map of module filenames to hashes of those files
        for file in fileset(v.Dir, "**") :
        (file) => filebase64sha512("${v.Dir}/${file}")
      }
    }
    # Only consider versioned modules. It's impossible to tell if something
    # should have changed or not if there's no associated version.
    # Filter on empty key because that appears to refer to the root.
    if v.Key != "" && (lookup(v, "Version", null) != null || v.Dir == local.this_module_path)
  } : null

  # Create a new map that also includes the module hashes
  modules_with_hashes = {
    for k, v in local.modules :
    k => merge(
      {
        # Remove the "files" element, we don't need to save that
        for k2, v2 in v :
        k2 => v2
        if k2 != "files"
      },
      {
        # Create a complete hash of all files
        hash = base64sha512(join(";", [
          for filename, filehash in v.files :
          "${base64sha512(filename)}:${filehash}"
        ]))
    })
  }

  # Find any modules where the hash doesn't match the locked hash
  mismatched_modules = local.lock_exists ? {
    for k, v in local.modules_with_hashes :
    k => v
    # Add it as a mismatch if 
    #   (a) the lock file knows of this module, 
    if lookup(local.module_lock, k, null) != null &&
    #   (b) the version matches, 
    v.version == local.module_lock[k].version &&
    #   (c) the source matches, and 
    v.source == local.module_lock[k].source &&
    #   (d) the hash does NOT match
    v.hash != local.module_lock[k].hash
  } : {}

  # Find all modules that have the same path as this module
  # (should just be one, which is this one)
  matching_modules = {
    for k, v in local.modules_with_hashes :
    k => v
    if v.directory == local.this_module_path
  }

  # Get the key for this module
  this_module_key = length(local.matching_modules) > 0 ? keys(local.matching_modules)[0] : null
  # Get the source for this module (e.g. Terraform Registry)
  this_module_source = local.this_module_key != null ? local.modules_with_hashes[local.this_module_key].source : null
  # Find all modules that have the same source
  modules_with_same_source_or_hash = local.this_module_key != null ? {
    for k, v in local.modules_with_hashes :
    k => v
    if v.source == local.modules_with_hashes[local.this_module_key].source || v.hash == local.modules_with_hashes[local.this_module_key].hash
  } : null
}

# Assert that this module is in the modules file.
# This is just a sanity check.
module "assert_this_module_present" {
  source    = "Invicton-Labs/assertion/null"
  version   = "~>0.2.4"
  condition = length(local.matching_modules) == 1
  error_message = length(local.matching_modules) == 0 ? (
    "The Invicton-Labs/module-lock/null module is not in the ${local.modules_json_file} file, which makes no sense since that's the module that's throwing this error.") : (
    "There are multiple modules in the ${local.modules_json_file} with the same path (${local.this_module_path}). If you had multiple but have since deleted one, or renamed this module, try deleting the ${local.modules_json_file} file and re-initialize."
  )
}

# Assert that there's only one copy of this module in the configuration.
module "assert_single_use" {
  source        = "Invicton-Labs/assertion/null"
  version       = "~>0.2.4"
  depends_on    = [module.assert_this_module_present]
  condition     = length(local.modules_with_same_source_or_hash) == 1
  error_message = "Only a single instance of the Invicton-Labs/module-lock/null module can exist in a Terraform configuration (found ${length(local.modules_with_same_source_or_hash)})"
}

# # Assert that the module hashes match the lock versions
module "assert_module_hashes_match" {
  source        = "Invicton-Labs/assertion/null"
  version       = "~>0.2.4"
  depends_on    = [module.assert_single_use]
  condition     = module.assert_this_module_present.checked && module.assert_single_use.checked && length(local.mismatched_modules) == 0
  error_message = "SECURITY RISK!!! The following ${length(local.mismatched_modules) > 1 ? "modules have different hashes, even though the sources/versions haven't changed" : "module has a different hash, even though the source/version hasn't changed"}: ${join(", ", [for k, v in local.mismatched_modules : k])}"
}

# Create/update the lock file
resource "local_file" "lock" {
  # Mark it sensitive so it doesn't clog the output
  content = sensitive(jsonencode(local.modules_with_hashes))
  # Force a dependency on the module check, so we don't overwrite the file
  # with the mismatched values if there are mismatches.
  filename = module.assert_module_hashes_match.checked ? local.lock_file : null
}
