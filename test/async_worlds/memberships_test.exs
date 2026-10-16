defmodule AsyncWorlds.MembershipsTest do
  # A rollback test installs a transaction-local history rejection trigger.
  use AsyncWorlds.DataCase, async: false

  alias AsyncWorlds.{Campaigns, Characters, Factions, LinkHistory, Memberships, Repo, Ticks}
  alias AsyncWorlds.Factions.Membership
  alias AsyncWorlds.Ticks.{Snapshot, WorldResolver}

  setup do
    [scope, other] =
      for {guild, dm} <- [{"123", "456"}, {"124", "457"}] do
        {:ok, campaign} =
          Campaigns.setup_campaign(%{
            discord_guild_id: guild,
            dm_user_id: dm,
            public_channel_id: "789"
          })

        %{campaign: campaign, discord_user_id: dm}
      end

    {:ok, character} =
      Characters.create_character(scope.campaign, scope.discord_user_id, %{
        name: "Mira",
        discord_user_id: "555"
      })

    {:ok, faction} =
      Factions.create_faction(scope, %{name: "Guild", description: "A trading guild"})

    {:ok, foreign_character} =
      Characters.create_character(other.campaign, other.discord_user_id, %{name: "Foreign"})

    {:ok, foreign_faction} = Factions.create_faction(other, %{name: "Foreign guild"})

    %{
      scope: scope,
      other: other,
      character: character,
      faction: faction,
      foreign_character: foreign_character,
      foreign_faction: foreign_faction
    }
  end

  test "join, role edit, leave and rejoin retain endpoint states after link removal", c do
    assert {:ok, joined} =
             Memberships.join(c.scope, to_string(c.character.id), to_string(c.faction.id))

    assert joined.role == nil
    assert joined.campaign_id == c.scope.campaign.id

    assert {:ok, edited} =
             Memberships.edit_role(c.scope, to_string(joined.id), %{"role" => "Scout"})

    assert edited.role == "Scout"
    assert {:ok, deleted} = Memberships.leave(c.scope, to_string(joined.id))
    assert deleted.id == joined.id
    refute Repo.get(Membership, joined.id)
    assert {:error, :not_found} = Memberships.leave(c.scope, joined.id)
    assert {:error, :not_found} = Memberships.edit_role(c.scope, joined.id, %{role: "No"})

    assert {:ok, rejoined} =
             Memberships.join(c.scope, c.character.id, c.faction.id, %{role: "Captain"})

    assert rejoined.id != joined.id

    assert {:ok, %{items: [join, edit, leave, rejoin]}} = LinkHistory.list_changes(c.scope)
    assert join.before == nil
    assert join.after == state(c, nil)
    assert edit.before == join.after
    assert edit.after == state(c, "Scout")
    assert leave.before == edit.after
    assert leave.after == nil
    assert rejoin.before == nil
    assert rejoin.after == state(c, "Captain")
    assert [join.link_id, edit.link_id, leave.link_id] == List.duplicate(joined.id, 3)
    assert rejoin.link_id == rejoined.id

    assert Enum.map([join, edit, leave, rejoin], & &1.id) ==
             Enum.sort([join.id, edit.id, leave.id, rejoin.id])

    assert Enum.all?(
             [join, edit, leave, rejoin],
             &(&1.tick_number == 1 and &1.kind == :faction_membership and
                 &1.actor_id == c.scope.discord_user_id)
           )

    for {type, id} <- [{"character", c.character.id}, {"faction", c.faction.id}] do
      assert {:ok, %{items: [^join, ^edit, ^leave, ^rejoin]}} =
               LinkHistory.list_changes(c.scope, entity: {type, id})
    end
  end

  test "role clearing and unchanged roles have the correct no-op semantics", c do
    {:ok, membership} = Memberships.join(c.scope, c.character.id, c.faction.id, %{role: "Scout"})
    assert {:ok, ^membership} = Memberships.edit_role(c.scope, membership.id, %{role: "Scout"})
    assert {:ok, ^membership} = Memberships.edit_role(c.scope, membership.id, %{})
    assert {:ok, cleared} = Memberships.edit_role(c.scope, membership.id, %{role: " "})
    assert cleared.role == nil
    assert {:ok, ^cleared} = Memberships.edit_role(c.scope, membership.id, %{role: nil})
    assert {:ok, %{items: [_, change]}} = LinkHistory.list_changes(c.scope)
    assert change.before == state(c, "Scout")
    assert change.after == state(c, nil)
  end

  test "trusted endpoint assignment ignores injected ownership, identity, and history fields",
       c do
    attrs = %{
      role: "Scout",
      character_id: c.foreign_character.id,
      faction_id: c.foreign_faction.id,
      campaign_id: c.other.campaign.id,
      id: -1,
      tick_number: 99,
      actor_id: "999"
    }

    assert {:ok, membership} = Memberships.join(c.scope, c.character.id, c.faction.id, attrs)
    assert membership.character_id == c.character.id
    assert membership.faction_id == c.faction.id
    assert membership.campaign_id == c.scope.campaign.id
    assert membership.id > 0
    assert {:ok, ^membership} = Memberships.edit_role(c.scope, membership.id, attrs)
    assert {:ok, %{items: [record]}} = LinkHistory.list_changes(c.scope)
    assert record.tick_number == 1
    assert record.actor_id == c.scope.discord_user_id
    assert record.entity_refs == %{"character" => [c.character.id], "faction" => [c.faction.id]}
  end

  test "validation and duplicate joins leave current membership and history unchanged", c do
    for role <- [String.duplicate("a", 201), "bad" <> <<0>>, <<255>>, 123, %{}] do
      assert {:error, %Ecto.Changeset{}} =
               Memberships.join(c.scope, c.character.id, c.faction.id, %{role: role})
    end

    assert Repo.aggregate(Membership, :count) == 0
    assert {:ok, %{items: []}} = LinkHistory.list_changes(c.scope)
    {:ok, membership} = Memberships.join(c.scope, c.character.id, c.faction.id, %{role: "Scout"})

    assert {:error, duplicate} =
             Memberships.join(c.scope, c.character.id, c.faction.id, %{role: "Captain"})

    assert duplicate.errors[:character_id]

    assert {:error, %Ecto.Changeset{}} =
             Memberships.edit_role(c.scope, membership.id, %{role: "bad" <> <<0>>})

    assert Repo.get!(Membership, membership.id) == membership
    assert {:ok, %{items: [_]}} = LinkHistory.list_changes(c.scope)
  end

  test "stable faction members and character affiliations preload both endpoints", c do
    {:ok, second_character} =
      Characters.create_character(c.scope.campaign, c.scope.discord_user_id, %{name: "Rook"})

    {:ok, second_faction} = Factions.create_faction(c.scope, %{name: "Other guild"})
    assert {:ok, []} = Memberships.list_faction_members(c.scope, c.faction.id)
    assert {:ok, []} = Memberships.list_character_affiliations(c.scope, c.character.id)
    {:ok, first} = Memberships.join(c.scope, c.character.id, c.faction.id)
    {:ok, second} = Memberships.join(c.scope, second_character.id, c.faction.id, %{role: "Scout"})
    {:ok, third} = Memberships.join(c.scope, c.character.id, second_faction.id)
    {:ok, _} = Memberships.join(c.other, c.foreign_character.id, c.foreign_faction.id)
    assert {:ok, [a, b]} = Memberships.list_faction_members(c.scope, to_string(c.faction.id))
    assert [a.id, b.id] == [first.id, second.id]
    assert a.character == c.character
    assert b.character == second_character
    assert a.faction == c.faction

    assert {:ok, affiliations} =
             Memberships.list_character_affiliations(c.scope, to_string(c.character.id))

    assert Enum.map(affiliations, & &1.id) == [first.id, third.id]
    assert Enum.map(affiliations, & &1.faction.name) == [c.faction.name, second_faction.name]
    Memberships.leave(c.scope, first.id)
    assert {:ok, [remaining]} = Memberships.list_faction_members(c.scope, c.faction.id)
    assert remaining.id == second.id
  end

  test "missing, malformed and foreign endpoints and membership IDs fail closed", c do
    {:ok, foreign} = Memberships.join(c.other, c.foreign_character.id, c.foreign_faction.id)
    invalid_ids = [nil, -1, 0, "bad", %{}, "999999999999999999999", "999999999"]

    for id <- [c.foreign_character.id | invalid_ids] do
      assert {:error, :not_found} = Memberships.join(c.scope, id, c.faction.id)
      assert {:error, :not_found} = Memberships.list_character_affiliations(c.scope, id)
    end

    for id <- [c.foreign_faction.id | invalid_ids] do
      assert {:error, :not_found} = Memberships.join(c.scope, c.character.id, id)
      assert {:error, :not_found} = Memberships.list_faction_members(c.scope, id)
    end

    for id <- [foreign.id | invalid_ids] do
      assert {:error, :not_found} = Memberships.edit_role(c.scope, id, %{role: "No"})
      assert {:error, :not_found} = Memberships.leave(c.scope, id)
    end

    assert Repo.get!(Membership, foreign.id) == foreign
    assert {:ok, %{items: []}} = LinkHistory.list_changes(c.scope)
  end

  test "all operations freshly authorize, and a descriptive role grants no permissions", c do
    {:ok, membership} =
      Memberships.join(c.scope, c.character.id, c.faction.id, %{role: "DM / administrator"})

    operations = [
      &Memberships.join(&1, c.character.id, c.faction.id),
      &Memberships.edit_role(&1, membership.id, %{role: "No"}),
      &Memberships.leave(&1, membership.id),
      &Memberships.list_faction_members(&1, c.faction.id),
      &Memberships.list_character_affiliations(&1, c.character.id)
    ]

    for operation <- operations do
      assert {:error, :unauthorized} = operation.(%{c.scope | discord_user_id: "555"})
      assert {:error, :invalid_scope} = operation.(%{})
      assert {:error, :invalid_id} = operation.(%{c.scope | discord_user_id: "bad"})
    end

    Repo.update!(change(c.scope.campaign, public_channel_id: "790"))
    for operation <- operations, do: assert({:error, :stale_campaign} = operation.(c.scope))
    Repo.update!(change(c.scope.campaign, dm_user_id: "999"))
    for operation <- operations, do: assert({:error, :unauthorized} = operation.(c.scope))
    assert Repo.get!(Membership, membership.id) == membership
  end

  test "database enforces pair uniqueness, required endpoints and same-campaign foreign keys",
       c do
    {:ok, membership} = Memberships.join(c.scope, c.character.id, c.faction.id)

    invalid = [
      %Membership{
        campaign_id: c.scope.campaign.id,
        character_id: c.character.id,
        faction_id: c.faction.id
      },
      %Membership{
        campaign_id: c.scope.campaign.id,
        character_id: c.foreign_character.id,
        faction_id: c.faction.id
      },
      %Membership{
        campaign_id: c.scope.campaign.id,
        character_id: c.character.id,
        faction_id: c.foreign_faction.id
      },
      %Membership{campaign_id: -1, character_id: c.character.id, faction_id: c.faction.id},
      %Membership{campaign_id: c.scope.campaign.id, character_id: -1, faction_id: c.faction.id},
      %Membership{campaign_id: c.scope.campaign.id, character_id: c.character.id, faction_id: -1}
    ]

    for row <- invalid do
      assert {:error, %Ecto.Changeset{}} =
               Repo.insert(Membership.changeset(row, %{}), mode: :savepoint)
    end

    assert_raise Postgrex.Error, fn ->
      Repo.insert!(
        Membership.changeset(
          %Membership{campaign_id: c.scope.campaign.id, faction_id: c.faction.id},
          %{}
        ), mode: :savepoint)
    end

    assert Repo.get!(Membership, membership.id) == membership
  end

  test "live memberships restrict entity deletion; explicit leave retains history after endpoint deletion",
       c do
    {:ok, membership} = Memberships.join(c.scope, c.character.id, c.faction.id)
    assert {:error, :faction_has_memberships} = Factions.delete_faction(c.scope, c.faction.id)
    assert_raise Ecto.ConstraintError, fn -> Repo.delete(c.faction, mode: :savepoint) end
    assert_raise Ecto.ConstraintError, fn -> Repo.delete(c.character, mode: :savepoint) end
    assert {:ok, _} = Memberships.leave(c.scope, membership.id)
    assert {:ok, _} = Factions.delete_faction(c.scope, c.faction.id)
    Repo.delete!(c.character)

    assert {:ok, %{items: [joined, left]}} =
             LinkHistory.list_changes(c.scope, entity: {"character", c.character.id})

    assert joined.after == left.before
    assert left.after == nil

    assert {:ok, %{items: [^joined, ^left]}} =
             LinkHistory.list_changes(c.scope, entity: {"faction", c.faction.id})
  end

  test "whole-campaign deletion cascades current memberships and retained history", c do
    {:ok, membership} = Memberships.join(c.scope, c.character.id, c.faction.id)
    Repo.delete!(c.scope.campaign)
    refute Repo.get(Membership, membership.id)
    assert Repo.aggregate(AsyncWorlds.LinkHistory.Change, :count) == 0
  end

  test "history failure rolls back join, role edit and leave", c do
    {:ok, membership} = Memberships.join(c.scope, c.character.id, c.faction.id, %{role: "Scout"})
    {:ok, another} = Factions.create_faction(c.scope, %{name: "Other guild"})
    {:ok, before} = LinkHistory.list_changes(c.scope)

    Repo.query!("""
    CREATE FUNCTION pg_temp.reject_membership_history() RETURNS trigger AS $$
    BEGIN RAISE EXCEPTION 'history unavailable'; END;
    $$ LANGUAGE plpgsql
    """)

    Repo.query!("""
    CREATE TRIGGER reject_membership_history BEFORE INSERT ON link_changes
    FOR EACH ROW EXECUTE FUNCTION pg_temp.reject_membership_history()
    """)

    for operation <- [
          fn -> Memberships.join(c.scope, c.character.id, another.id) end,
          fn -> Memberships.edit_role(c.scope, membership.id, %{role: "Captain"}) end,
          fn -> Memberships.leave(c.scope, membership.id) end
        ] do
      assert_raise Postgrex.Error, fn -> Repo.transaction(operation, mode: :savepoint) end
      assert Repo.get!(Membership, membership.id) == membership
      assert Repo.aggregate(Membership, :count) == 1
      assert {:ok, ^before} = LinkHistory.list_changes(c.scope)
    end
  end

  test "member projections and character ownership, flags and state generations are unchanged",
       c do
    character = Repo.get!(Characters.Character, c.character.id)
    campaign = Repo.get!(Campaigns.Campaign, c.scope.campaign.id)
    {:ok, player} = Characters.player_character(campaign.discord_guild_id, "555")
    {:ok, factions} = Factions.list_campaign_factions(campaign.discord_guild_id)
    {:ok, faction} = Factions.get_campaign_faction(campaign.discord_guild_id, c.faction.id)
    jobs = Repo.aggregate(Oban.Job, :count)
    deliveries = Repo.aggregate(AsyncWorlds.Deliveries.Delivery, :count)
    {:ok, membership} = Memberships.join(c.scope, c.character.id, c.faction.id, %{role: "Leader"})
    {:ok, _} = Memberships.edit_role(c.scope, membership.id, %{role: "Captain"})
    {:ok, _} = Memberships.leave(c.scope, membership.id)
    assert Repo.get!(Characters.Character, character.id) == character
    assert Repo.get!(Campaigns.Campaign, campaign.id) == campaign
    assert {:ok, ^player} = Characters.player_character(campaign.discord_guild_id, "555")
    assert {:ok, ^factions} = Factions.list_campaign_factions(campaign.discord_guild_id)

    assert {:ok, ^faction} =
             Factions.get_campaign_faction(campaign.discord_guild_id, c.faction.id)

    assert Repo.aggregate(Oban.Job, :count) == jobs
    assert Repo.aggregate(AsyncWorlds.Deliveries.Delivery, :count) == deliveries
  end

  test "descriptive memberships do not alter quest inputs, progression, drafts or published output",
       c do
    {:ok, revision} =
      AsyncWorlds.Quests.create_quest(
        c.scope.campaign,
        c.scope.discord_user_id,
        %{content_id: "quest", name: "Quest"},
        AsyncWorlds.QuestFixtures.definition()
      )

    {:ok, progression} =
      AsyncWorlds.Quests.assign(
        c.scope.campaign,
        c.scope.discord_user_id,
        c.character.id,
        revision.id
      )

    {:ok, tick} = Ticks.open_tick(c.scope.campaign.id)
    {:ok, player_state} = AsyncWorlds.Quests.Submissions.player_state("123", "555")
    {:ok, _} = AsyncWorlds.Quests.Submissions.submit("123", "555", player_state.identity, "loop")

    submission =
      Repo.get_by!(AsyncWorlds.Quests.Submission, tick_id: tick.id, character_id: c.character.id)

    {:ok, %{snapshot: snapshot}} = Ticks.close_tick(c.scope.campaign.id, tick.id)
    character = Repo.get!(Characters.Character, c.character.id)
    {:ok, membership} = Memberships.join(c.scope, c.character.id, c.faction.id, %{role: "Scout"})
    assert Repo.get!(AsyncWorlds.Quests.Progression, progression.id) == progression
    assert Repo.get!(AsyncWorlds.Quests.Submission, submission.id) == submission
    assert Repo.get!(AsyncWorlds.Quests.Revision, revision.id) == revision
    assert Repo.get!(Snapshot, snapshot.id) == snapshot
    {:ok, payload} = WorldResolver.resolve(snapshot)

    {:ok, %{draft: draft}} =
      Ticks.put_draft(c.scope.campaign.id, tick.id, snapshot.revision, payload)

    {:ok, _} = Memberships.edit_role(c.scope, membership.id, %{role: "Leader"})
    assert Repo.get!(AsyncWorlds.Ticks.Draft, draft.id) == draft
    assert Repo.get!(Characters.Character, character.id) == character
    {:ok, _} = Ticks.publish_tick(c.scope.campaign.id, tick.id, draft.id)
    publication = Repo.get_by!(AsyncWorlds.Ticks.Publication, tick_id: tick.id)
    published_character = Repo.get!(Characters.Character, character.id)
    published_progression = Repo.get!(AsyncWorlds.Quests.Progression, progression.id)
    deliveries = Repo.all(AsyncWorlds.Deliveries.Delivery)
    {:ok, _} = Memberships.leave(c.scope, membership.id)
    assert Repo.get!(AsyncWorlds.Ticks.Publication, publication.id) == publication
    assert Repo.get!(Characters.Character, character.id) == published_character
    assert Repo.get!(AsyncWorlds.Quests.Progression, progression.id) == published_progression
    assert Repo.all(AsyncWorlds.Deliveries.Delivery) == deliveries
  end

  test "membership writes follow actual tick lifecycle without taking gameplay locks", c do
    {:ok, membership} = Memberships.join(c.scope, c.character.id, c.faction.id)
    {:ok, %{items: [setup]}} = LinkHistory.list_changes(c.scope)
    assert setup.tick_number == 1
    assert Ticks.active_tick(c.scope.campaign.id) == nil
    {:ok, tick} = Ticks.open_tick(c.scope.campaign.id)
    {:ok, _} = Memberships.edit_role(c.scope, membership.id, %{role: "Scout"})
    {:ok, %{items: first_records}} = LinkHistory.list_changes(c.scope, tick_number: 1)
    assert length(first_records) == 2
    {:ok, %{snapshot: snapshot}} = Ticks.close_tick(c.scope.campaign.id, tick.id)
    character = Repo.get!(Characters.Character, c.character.id)
    {:ok, _} = Memberships.edit_role(c.scope, membership.id, %{role: "Captain"})
    {:ok, payload} = WorldResolver.resolve(snapshot)

    {:ok, %{draft: draft}} =
      Ticks.put_draft(c.scope.campaign.id, tick.id, snapshot.revision, payload)

    deliveries = Repo.all(AsyncWorlds.Deliveries.Delivery)
    jobs = Repo.all(Oban.Job)
    {:ok, _} = Memberships.leave(c.scope, membership.id)
    assert Repo.all(AsyncWorlds.Deliveries.Delivery) == deliveries
    assert Repo.all(Oban.Job) == jobs
    assert Repo.get!(Characters.Character, c.character.id) == character
    assert Repo.get!(Snapshot, snapshot.id) == snapshot
    {:ok, %{items: future}} = LinkHistory.list_changes(c.scope, tick_number: 2)
    assert length(future) == 2
    {:ok, _} = Ticks.publish_tick(c.scope.campaign.id, tick.id, draft.id)
    {:ok, rejoined} = Memberships.join(c.scope, c.character.id, c.faction.id)
    assert rejoined.id != membership.id
    {:ok, next} = Ticks.open_tick(c.scope.campaign.id)
    assert next.number == 2
    assert {:ok, %{items: records}} = LinkHistory.list_changes(c.scope, tick_number: next.number)
    assert Enum.take(records, 2) == future
    assert length(records) == 3
    assert {:ok, %{items: ^first_records}} = LinkHistory.list_changes(c.scope, tick_number: 1)
  end

  defp state(c, role),
    do: %{"character_id" => c.character.id, "faction_id" => c.faction.id, "role" => role}
end
