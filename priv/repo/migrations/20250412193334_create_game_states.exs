defmodule Constellation.Repo.Migrations.CreateGameStates do
  use Ecto.Migration

  def change do
    create table(:game_states) do
      add :current_round, :integer, default: 1, null: false
      add :current_letter, :string, null: false
      add :round_stopped, :boolean, default: false, null: false
      add :game_id, references(:games, on_delete: :delete_all), null: false

      timestamps(type: :utc_datetime)
    end

    create unique_index(:game_states, [:game_id])
  end
end
