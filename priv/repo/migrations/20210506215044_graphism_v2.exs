defmodule(Graphism.Migration.V2) do
  use(Ecto.Migration)

  def(up) do
    create(table(:permissions, primary_key: false)) do
      add(:id, :uuid, null: false, primary_key: true)
      add(:name, :string, null: false)
    end

    create(unique_index(:permissions, [:name], name: :unique_name_per_permissions))
  end

  def(down) do
    []
  end
end