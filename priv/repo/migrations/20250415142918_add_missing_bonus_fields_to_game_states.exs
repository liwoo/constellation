defmodule Constellation.Repo.Migrations.AddMissingBonusFieldsToGameStates do
  use Ecto.Migration

  def up do
    # Add bonus_points column if it doesn't exist
    unless column_exists?(:game_states, :bonus_points) do
      alter table(:game_states) do
        add :bonus_points, :map, default: %{}
      end
    end

    # Add total_scores column if it doesn't exist
    unless column_exists?(:game_states, :total_scores) do
      alter table(:game_states) do
        add :total_scores, :map, default: %{}
      end
    end
  end

  def down do
    # We don't want to drop these columns in down migration
    # as they might be used by other migrations
    :ok
  end

  # Helper function to check if a column exists
  defp column_exists?(table, column) do
    query = """
    SELECT column_name FROM information_schema.columns 
    WHERE table_name='#{table}' AND column_name='#{column}'
    """
    case repo().query(query) do
      {:ok, %{num_rows: n}} -> n > 0
      _ -> false
    end
  end
end
