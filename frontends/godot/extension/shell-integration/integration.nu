# Nushell emits prompt boundaries natively; preserve other user settings.
$env.config.shell_integration.osc133 = true
$env.config.shell_integration.osc7 = false
$env.config.hooks.pre_prompt = ($env.config.hooks.pre_prompt | append {||
  let directory = ($env.PWD | url encode --all | str replace --all '%2F' '/')
  print -n $"(ansi osc)7;file://localhost($directory)(ansi st)"
})
