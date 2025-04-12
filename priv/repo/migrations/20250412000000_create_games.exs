defmodule Constellation.Repo.Migrations.CreateGames do
  use Ecto.Migration

  def change do
    create table(:games) do
      add :name, :string, null: false
      add :status, :string, null: false, default: "waiting"
      add :owner_id, :string, null: false
      add :min_players, :integer, null: false, default: 2
      add :max_players, :integer, null: false, default: 8

      timestamps()
    end

    create index(:games, [:status])
  end
end
