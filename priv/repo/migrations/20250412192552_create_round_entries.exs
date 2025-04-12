defmodule Constellation.Repo.Migrations.CreateRoundEntries do
  use Ecto.Migration

  def change do
    create table(:round_entries) do
      add :round_number, :integer, null: false
      add :letter, :string, null: false
      add :category, :string, null: false
      add :answer, :string, null: false
      add :score, :integer, default: 0
      add :player_id, references(:players, on_delete: :delete_all), null: false
      add :game_id, references(:games, on_delete: :delete_all), null: false

      timestamps(type: :utc_datetime)
    end

    create index(:round_entries, [:player_id])
    create index(:round_entries, [:game_id])
    create index(:round_entries, [:round_number])
    create index(:round_entries, [:game_id, :round_number])
  end
end
