# QForce Performance (ReqRes)

JMeter tests live under **`Services/ReqRes/`**, grouped by module:

- **`products`**: `Products.jmx`, `Posts.jmx`
- **`users`**: `Users.jmx`

**`ENV`** is `dev` or `prod` (sent on the request as **`x-reqres-env`**). The API host is **`SERVICE_BASE_URL`** (HTTPS host only, no scheme; use **`reqres.in`** for the public ReqRes API).

## Repository layout

```
Services/ReqRes/
  testplans/
    products/          # Products.jmx, Posts.jmx
    users/             # Users.jmx
scripts/
  run-jmeter.sh        # Run a single plan locally or on an agent
  prepare-results-dir.sh
JenkinsFile            # Jenkins pipeline
```

Test output goes under **`results/`** (ignored by git; see `.gitignore`).

## Local run

```bash
export REQRES_API_KEY_DEV="<key>"
export REQRES_API_KEY_PROD="<key>"
export JMETER_HOME=/opt/apache-jmeter-5.6.3   # or set JMETER_BIN / use jmeter on PATH

./scripts/run-jmeter.sh ReqRes products Posts.jmx reqres.in 10 5 1 dev LOOP ALL
./scripts/run-jmeter.sh ReqRes users Users.jmx reqres.in 10 5 1 dev LOOP ALL
```

### Arguments

| Position | Name | Notes |
|----------|------|--------|
| 1 | `service` | `ReqRes` |
| 2 | `module` | `products` or `users` |
| 3 | `test_plan` | e.g. `Posts.jmx` |
| 4 | `service_base_url` | Host only, e.g. `reqres.in` |
| 5–7 | `threads`, `rampup`, `loops_or_duration` | |
| 8 | `env` | `dev` or `prod` (`dev`/`prod` and `DEV`/`PROD` accepted for key selection) |
| 9 | `mode` | `LOOP` or `DURATION` (default `LOOP`) |
| 10 | `test_action` | Default `ALL` |

JMeter is invoked with **`-JSERVICE_BASE_URL=…`** (not `BASE_URL`). Plans also use **`-JENV`**, **`-JAPI_KEY`**, **`-JTEST_ACTION`**, and thread/ramp/duration properties as defined in each `.jmx`.

## Jenkins

- **SERVICE**: `ReqRes`
- **MODULE**: `products` or `users` (for SINGLE / MODULE runs)
- **SERVICE_BASE_URL**: defaults to `reqres.in` when unset
- **ENV**: `dev` or `prod` (same as `x-reqres-env`)
- Credentials: **`REQRES_API_KEY_DEV`**, **`REQRES_API_KEY_PROD`**

## Authoring new plans

There is no shared template file in this repo. Copy an existing plan under **`testplans/products/`** or **`testplans/users/`** and keep the same user-defined properties pattern (`SERVICE_BASE_URL`, `ENV`, `API_KEY`, `TEST_ACTION`, etc.) and headers **`x-reqres-env`**, **`x-api-key`**, consistent with the current `.jmx` files.
