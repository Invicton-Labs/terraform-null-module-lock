# Terraform Module Lock

This module is a solution to [this issue](https://github.com/hashicorp/terraform/issues/29867), which details how the source code of modules in the Terraform Registry can change without the version number changing. This issue opens a major security hole, allowing malicious code to be injected without users being aware.

To use this module, simply drop it into a Terraform file in the base directory of your configuration, like so:

```
module "module_lock" {
  source = "Invicton-Labs/module-lock/null"
}
```

This module will automatically create a hash of all files in each module and store them in a lock file (`.terraform.modules.lock.json`). On every subsequent run, it will check the hashes of each downloaded module and compare them with the lock file hash. If there's a difference, when the source or version haven't changed, it will halt the execution during the plan phase and throw an error.

Note that it is still possible for malicious code to be injected and it may run before this module runs its checks. To prevent that, you can have all other modules depend on this one, preventing them from being run before this module completes its checks:
```
module "module_lock" {
  source = "Invicton-Labs/module-lock/null"
}

module "other_module_1" {
    source = "..."
    depends_on = [module.module_lock]
}

module "other_module_2" {
    source = "..."
    depends_on = [module.module_lock]
}
```

While this is annoying and there is a high risk of forgetting to do it, it's still better than nothing!

**Write to HashiCorp and insist that module versions be pinnable to hashes instead of tags.**
