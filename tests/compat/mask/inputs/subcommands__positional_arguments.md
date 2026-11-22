

## services

> Commands related to starting, stopping, and restarting services

### services start (service_name)

> Start a service.

~~~bash
echo "Starting service $service_name"
~~~

~~~powershell
param(
    $service_name = $env:service_name
)

Write-Output "Starting service $service_name"
~~~

### services stop (service_name)

> Stop a service.

~~~bash
echo "Stopping service $service_name"
~~~

~~~powershell
param(
    $service_name = $service_name
)

Write-Output "Stopping service $service_name"
~~~
