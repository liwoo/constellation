defmodule Constellation.Repo.Migrations.AddVerificationFieldsToRoundEntries do
  use Ecto.Migration

  def change do
    alter table(:round_entries) do
      add :verification_status, :string, default: "pending"
      add :is_valid, :boolean, default: nil
      add :ai_explanation, :text
    end
    
    # Add an index to help with querying by verification status
    create index(:round_entries, [:verification_status])
  end
end
