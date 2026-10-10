#!/usr/bin/env bash
# Requires an EXTERNALLY supplied disposable, empty PostgreSQL database.
# Never creates, stops, or deletes a database/container belonging to the caller.
set -euo pipefail
: "${SMOKE_DATABASE_URL:?Supply a disposable external PostgreSQL database URL}"
: "${SMOKE_ALLOW_DATABASE_WRITES:?Set to yes to acknowledge migrations/setup/test writes}"
[[ "$SMOKE_ALLOW_DATABASE_WRITES" == yes ]]
image=${SMOKE_IMAGE:-async-worlds:smoke}
name="eng11-smoke-$(date +%s)-$$"
work=$(mktemp -d)
chmod 700 "$work"
network=()
[[ -z "${SMOKE_NETWORK:-}" ]] || network=(--network "$SMOKE_NETWORK")
cleanup() {
  docker logs "$name" > "$work/app.log" 2>&1 || true
  if [[ -n "${SMOKE_LOG_DIR:-}" ]]; then
    mkdir -p "$SMOKE_LOG_DIR"
    cp "$work/app.log" "$SMOKE_LOG_DIR/$name.log"
  fi
  docker rm -f "$name" >/dev/null 2>&1 || true
  rm -rf "$work"
}
trap cleanup EXIT
# Dummy values only. No Discord gateway or OAuth network requests are made.
cat > "$work/runtime.env" <<EOF
DATABASE_URL=$SMOKE_DATABASE_URL
DATABASE_SSL=${SMOKE_DATABASE_SSL:-verify}
SECRET_KEY_BASE=$(printf 'smoke-only-%.0s' {1..8})
PHX_HOST=smoke.example
DISCORD_ENABLED=false
DISCORD_OAUTH_CLIENT_ID=dummy-client
DISCORD_OAUTH_CLIENT_SECRET=dummy-secret
DISCORD_OAUTH_REDIRECT_URI=https://smoke.example/auth/discord/callback
DISCORD_GUILD_ID=111
DISCORD_DM_USER_ID=222
DISCORD_PUBLIC_CHANNEL_ID=333
EOF
extra=()
if [[ -n "${SMOKE_CA_CERT:-}" ]]; then
  extra=(-v "$SMOKE_CA_CERT:/run/db-ca.pem:ro" -e DATABASE_CA_CERT=/run/db-ca.pem)
fi
run_eval() {
  docker run --rm "${network[@]}" "${extra[@]}" --env-file "$work/runtime.env" -e PHX_SERVER=false "$image" /app/bin/async_worlds eval "$1"
}
if [[ "${SMOKE_SKIP_BUILD:-false}" != true ]]; then docker build -t "$image" .; fi
run_eval 'AsyncWorlds.Release.migrate()'
run_eval 'AsyncWorlds.Release.migrate()'
run_eval 'c = AsyncWorlds.Release.setup(); true = c.current_tick_number == 0'
run_eval 'c = AsyncWorlds.Release.setup(); true = c.dm_user_id == "222"'
# Actual release startup failures, not just string/config assertions.
for bad in DATABASE_URL SECRET_KEY_BASE DISCORD_OAUTH_CLIENT_SECRET PHX_HOST; do
  if docker run --rm "${network[@]}" --env-file "$work/runtime.env" -e "$bad=" "$image" /app/bin/async_worlds eval 'IO.puts("unexpected startup")' > "$work/failure.log" 2>&1; then
    echo "ERROR: missing $bad was accepted"; exit 1
  fi
  grep -q "$bad" "$work/failure.log"
done
# Malformed paths must fail before Ecto's InvalidURLError can print the URL/password.
if docker run --rm "${network[@]}" --env-file "$work/runtime.env" -e 'DATABASE_URL=postgres://user:smoke-sensitive-password@db.example/worlds/extra' "$image" /app/bin/async_worlds eval 'IO.puts("unexpected startup")' > "$work/failure.log" 2>&1; then
  echo 'ERROR: malformed database path was accepted'; exit 1
fi
grep -q DATABASE_URL "$work/failure.log"
if grep -q smoke-sensitive-password "$work/failure.log"; then
  echo 'ERROR: database startup diagnostic leaked credentials'; exit 1
fi
if docker run --rm "${network[@]}" --env-file "$work/runtime.env" -e DISCORD_ENABLED=true "$image" /app/bin/async_worlds eval 'IO.puts("unexpected startup")' > "$work/failure.log" 2>&1; then
  echo 'ERROR: enabled bot without token was accepted'; exit 1
fi
grep -q DISCORD_BOT_TOKEN "$work/failure.log"
for bad in 'DATABASE_SSL=require' 'DISCORD_OAUTH_REDIRECT_URI=http://smoke.example/auth/discord/callback'; do
  if docker run --rm "${network[@]}" --env-file "$work/runtime.env" -e "$bad" "$image" /app/bin/async_worlds eval 'IO.puts("unexpected startup")' > "$work/failure.log" 2>&1; then
    echo "ERROR: invalid ${bad%%=*} was accepted"; exit 1
  fi
  grep -q "${bad%%=*}" "$work/failure.log"
done
docker run -d --name "$name" "${network[@]}" "${extra[@]}" --env-file "$work/runtime.env" --restart unless-stopped --stop-timeout 180 "$image" >/dev/null
wait_ready() {
  for _ in {1..60}; do
    if docker exec "$name" curl -fsS http://127.0.0.1:4000/health/ready > "$work/ready.json" 2>/dev/null; then
      grep -q '"database":"ok"' "$work/ready.json"; return
    fi
    sleep 1
  done
  echo 'ERROR: readiness timed out'; docker logs "$name"; exit 1
}
rpc() { docker exec "$name" /app/bin/async_worlds rpc "$1"; }
wait_ready
docker exec "$name" curl -fsS http://127.0.0.1:4000/health/live
rpc 'nil = Process.whereis(AsyncWorlds.Discord.Supervisor); nil = Process.whereis(Nostrum.Supervisor)'
# Insert a real Oban scheduled job in the running instance, then assert its ID,
# payload, schedule and state survive a graceful stop/start against external PG.
rpc '{:ok, job} = %{campaign_id: 0, tick_id: 0, input_revision: 1, smoke: true} |> AsyncWorlds.Workers.ResolveTick.new(schedule_in: 86400) |> Oban.insert(); File.write!("/tmp/smoke-job-id", Integer.to_string(job.id))'
rpc 'c = AsyncWorlds.Campaigns.fetch_campaign_by_guild("111"); {:ok, campaign} = c; {:error, :unauthorized} = AsyncWorlds.Campaigns.authorize_dm("111", "444"); {:ok, _} = AsyncWorlds.Campaigns.authorize_dm("111", campaign.dm_user_id)'
# HTTP outside probes must retain HTTPS enforcement and DM login protection.
docker exec "$name" sh -ec 'curl -sS -D /tmp/headers -o /dev/null -H "Host: smoke.example" http://127.0.0.1:4000/; grep -q "location: https://" /tmp/headers'
docker exec "$name" sh -ec 'curl -fsS -D /tmp/oauth-headers -o /dev/null -H "Host: smoke.example" -H "X-Forwarded-Proto: https" http://127.0.0.1:4000/auth/discord; grep -qi "set-cookie:.*secure" /tmp/oauth-headers; grep -qi "set-cookie:.*HttpOnly" /tmp/oauth-headers; grep -q "location: https://discord.com/" /tmp/oauth-headers; curl -sS -D /tmp/dm-headers -o /dev/null -H "Host: smoke.example" -H "X-Forwarded-Proto: https" http://127.0.0.1:4000/dashboard; grep -q "location: /login" /tmp/dm-headers'
docker stop -t 180 "$name" >/dev/null
[[ $(docker inspect -f '{{.State.ExitCode}}' "$name") == 0 ]]
docker start "$name" >/dev/null
wait_ready
persisted='id = "/tmp/smoke-job-id" |> File.read!() |> String.to_integer(); job = AsyncWorlds.Repo.get!(Oban.Job, id); "scheduled" = job.state; true = job.args["smoke"]; true = DateTime.compare(job.scheduled_at, DateTime.utc_now()) == :gt'
rpc "$persisted"
# Also exercise Docker's configured crash restart, not merely docker start.
rpc 'System.halt(1)' >/dev/null 2>&1 || true
wait_ready
[[ $(docker inspect -f '{{.RestartCount}}' "$name") -gt 0 ]]
rpc "$persisted; :ok = Oban.cancel_job(id)"
rpc 'nil = Process.whereis(AsyncWorlds.Discord.Supervisor)'
# Prove a broken DB connection returns only the fixed safe diagnostic. This is
# application configuration in our container; the supplied DB is not stopped.
rpc ':ok = Supervisor.terminate_child(AsyncWorlds.Supervisor, AsyncWorlds.Repo)'
docker exec "$name" sh -ec 'code=$(curl -sS -o /tmp/ready-failed -w "%{http_code}" http://127.0.0.1:4000/health/ready); test "$code" = 503; curl -fsS http://127.0.0.1:4000/health/live'
rpc 'body = "/tmp/ready-failed" |> File.read!() |> Jason.decode!(); true = body == %{"database" => "unavailable", "status" => "unavailable"}'
echo 'PASS: migrations, idempotent setup, runtime failures, health/DB diagnostics, HTTPS, bot disabled, SIGTERM, crash restart and persisted Oban job'
