defmodule AsyncWorlds.WorldRelationshipMigrationTest do
  # Deliberately NOT DataCase: migrations run against a disposable database, never
  # down-migrating the suite database or relying on a sandbox DDL rollback.
  use ExUnit.Case, async: false
  alias AsyncWorlds.WorldMigrationRepo, as: Repo

  test "existing rows survive forward migration with empty defaults and real reference safety" do
    config =
      AsyncWorlds.Repo.config()
      |> Keyword.drop([:name, :pool])
      |> Keyword.merge(
        database: "eng88_migration_#{System.unique_integer([:positive])}",
        pool_size: 2
      )

    assert :ok = Ecto.Adapters.Postgres.storage_up(config)
    on_exit(fn -> assert :ok = Ecto.Adapters.Postgres.storage_down(config) end)
    start_supervised!({Repo, config})
    migrations = Application.app_dir(:async_worlds, "priv/repo/migrations")
    Ecto.Migrator.run(Repo, migrations, :up, to: 20_261_014_205_414, log: false)

    [campaign, foreign] =
      for guild <- ["123", "124"] do
        scalar(
          """
          INSERT INTO campaigns (discord_guild_id, dm_user_id, public_channel_id, inserted_at, updated_at)
          VALUES ($1, '456', '789', now(), now()) RETURNING id
          """,
          [guild]
        )
      end

    root = entity("locations", campaign, "Old region")
    child = entity("locations", campaign, "Old city")
    foreign_location = entity("locations", foreign, "Foreign")
    faction = entity("factions", campaign, "Old guild")
    foreign_faction = entity("factions", foreign, "Foreign guild")
    character = entity("characters", campaign, "Old hero")
    foreign_character = entity("characters", foreign, "Foreign hero")
    query("UPDATE locations SET description = 'Existing location prose'")
    query("UPDATE factions SET description = 'Existing faction prose'")

    query("""
    UPDATE characters SET discord_user_id = '555',
      flags = '{"ready":{"type":"boolean","value":true,"player_visible":false}}'
    """)

    old_locations =
      query(
        "SELECT id, campaign_id, name, description, inserted_at, updated_at FROM locations ORDER BY id"
      ).rows

    old_characters = query("SELECT * FROM characters ORDER BY id").rows
    old_factions = query("SELECT * FROM factions ORDER BY id").rows
    Ecto.Migrator.run(Repo, migrations, :up, all: true, log: false)

    assert query(
             "SELECT id, campaign_id, name, description, inserted_at, updated_at FROM locations ORDER BY id"
           ).rows == old_locations

    assert query("SELECT * FROM characters ORDER BY id").rows == old_characters
    assert query("SELECT * FROM factions ORDER BY id").rows == old_factions

    assert query("SELECT parent_id, kind FROM locations").rows == [
             [nil, nil],
             [nil, nil],
             [nil, nil]
           ]

    assert scalar("SELECT count(*) FROM faction_memberships") == 0
    assert scalar("SELECT count(*) FROM link_changes") == 0

    violation(:foreign_key_violation, "UPDATE locations SET parent_id = $1 WHERE id = $2", [
      foreign_location,
      child
    ])

    violation(:foreign_key_violation, "UPDATE locations SET parent_id = 999999 WHERE id = $1", [
      child
    ])

    violation(:check_violation, "UPDATE locations SET parent_id = id WHERE id = $1", [child])
    query("UPDATE locations SET parent_id = $1 WHERE id = $2", [root, child])
    violation(:foreign_key_violation, "DELETE FROM locations WHERE id = $1", [root])

    insert =
      "INSERT INTO faction_memberships (campaign_id, character_id, faction_id, inserted_at, updated_at) VALUES ($1, $2, $3, now(), now()) RETURNING id"

    membership = scalar(insert, [campaign, character, faction])
    violation(:unique_violation, insert, [campaign, character, faction])
    violation(:foreign_key_violation, insert, [campaign, foreign_character, faction])
    violation(:foreign_key_violation, insert, [campaign, character, foreign_faction])
    violation(:foreign_key_violation, insert, [campaign, 999_999, faction])
    violation(:foreign_key_violation, "DELETE FROM characters WHERE id = $1", [character])
    violation(:foreign_key_violation, "DELETE FROM factions WHERE id = $1", [faction])

    # Retained endpoint identities intentionally do not reference the live link.
    retained =
      scalar(
        """
        INSERT INTO link_changes (campaign_id, tick_number, kind, link_id, entity_refs, "after", actor_id, inserted_at)
        VALUES ($1, 1, 'faction_membership', $2, $3, $4, '456', now()) RETURNING id
        """,
        [
          campaign,
          membership,
          %{"character" => [character], "faction" => [faction]},
          %{"character_id" => character, "faction_id" => faction, "role" => nil}
        ]
      )

    history = query("SELECT * FROM link_changes WHERE id = $1", [retained]).rows
    query("DELETE FROM faction_memberships WHERE id = $1", [membership])
    query("DELETE FROM factions WHERE id = $1", [faction])
    query("DELETE FROM characters WHERE id = $1", [character])
    assert query("SELECT * FROM link_changes WHERE id = $1", [retained]).rows == history

    violation(:raise_exception, "UPDATE link_changes SET actor_id = '999' WHERE id = $1", [
      retained
    ])

    violation(:raise_exception, "DELETE FROM link_changes WHERE id = $1", [retained])
    query("UPDATE locations SET parent_id = NULL WHERE id = $1", [child])
    query("DELETE FROM locations WHERE id = $1", [root])
    # Whole-campaign deletion remains possible even with live relationships.
    replacement_root = entity("locations", campaign, "Replacement region")
    query("UPDATE locations SET parent_id = $1 WHERE id = $2", [replacement_root, child])
    replacement_character = entity("characters", campaign, "Replacement hero")
    replacement_faction = entity("factions", campaign, "Replacement guild")
    scalar(insert, [campaign, replacement_character, replacement_faction])
    query("DELETE FROM campaigns WHERE id = $1", [campaign])
    assert scalar("SELECT count(*) FROM link_changes") == 0
    assert scalar("SELECT count(*) FROM faction_memberships") == 0
    assert scalar("SELECT count(*) FROM locations WHERE campaign_id = $1", [campaign]) == 0
    assert scalar("SELECT count(*) FROM locations WHERE campaign_id = $1", [foreign]) == 1
    assert scalar("SELECT count(*) FROM characters WHERE campaign_id = $1", [foreign]) == 1
    assert scalar("SELECT count(*) FROM factions WHERE campaign_id = $1", [foreign]) == 1
  end

  defp entity(table, campaign, name) do
    scalar(
      "INSERT INTO #{table} (campaign_id, name, inserted_at, updated_at) VALUES ($1, $2, now(), now()) RETURNING id",
      [campaign, name]
    )
  end

  defp query(sql, params \\ []), do: Ecto.Adapters.SQL.query!(Repo, sql, params)
  defp scalar(sql, params \\ []), do: query(sql, params).rows |> hd() |> hd()

  defp violation(code, sql, params) do
    assert {:error, %Postgrex.Error{postgres: %{code: ^code}}} =
             Ecto.Adapters.SQL.query(Repo, sql, params)
  end
end
