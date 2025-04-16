defmodule Constellation.Repo.Migrations.RenamePlayerAnswersColumn do
  use Ecto.Migration

  def up do
    # First check if player_answers column exists
    execute """
    DO $$
    BEGIN
      IF EXISTS (
        SELECT 1
        FROM information_schema.columns
        WHERE table_name = 'game_states' AND column_name = 'player_answers'
      ) THEN
        ALTER TABLE game_states RENAME COLUMN player_answers TO verified_answers_by_round;
      END IF;
    END
    $$;
    """

    # Then make sure verified_answers_by_round exists (add it if it doesn't)
    execute """
    DO $$
    BEGIN
      IF NOT EXISTS (
        SELECT 1
        FROM information_schema.columns
        WHERE table_name = 'game_states' AND column_name = 'verified_answers_by_round'
      ) THEN
        ALTER TABLE game_states ADD COLUMN verified_answers_by_round jsonb DEFAULT '{}'::jsonb;
      END IF;
    END
    $$;
    """

    # Make sure current_round_submissions exists
    execute """
    DO $$
    BEGIN
      IF NOT EXISTS (
        SELECT 1
        FROM information_schema.columns
        WHERE table_name = 'game_states' AND column_name = 'current_round_submissions'
      ) THEN
        ALTER TABLE game_states ADD COLUMN current_round_submissions jsonb DEFAULT '{}'::jsonb;
      END IF;
    END
    $$;
    """
  end

  def down do
    # This is a risky operation as it might lose data, so we don't provide a down migration
    # If you need to revert, you would need to manually handle the data migration
    :ok
  end
end
