defmodule(Graphism.Migration.V1) do
  use(Ecto.Migration)

  def(up) do
    create(table(:permissions, primary_key: false)) do
      add(:id, :uuid, null: false, primary_key: true)
      add(:name, :string, null: false)
      timestamps()
    end

    create(unique_index(:permissions, [:name], name: :unique_name_per_permissions))
    execute("create type roles_name as ENUM ('admin','user')")

    create(table(:roles, primary_key: false)) do
      add(:id, :uuid, null: false, primary_key: true)
      add(:name, :roles_name, default: "user", null: false)
      timestamps()
    end

    create(unique_index(:roles, [:name], name: :unique_name_per_roles))

    create(table(:super_users, primary_key: false)) do
      add(:email, :string, null: false)
      add(:first, :string, null: false)
      add(:id, :uuid, null: false, primary_key: true)
      add(:lang, :string, null: false)
      add(:last, :string, null: false)
      add(:verified, :boolean, null: false)
      timestamps()
    end

    create(table(:super_user_roles, primary_key: false)) do
      add(:id, :uuid, null: false, primary_key: true)
      add(:role_id, references(:roles, type: :uuid), null: false)
      add(:super_user_id, references(:super_users, type: :uuid), null: false)
      timestamps()
    end

    create(table(:tokens, primary_key: false)) do
      add(:expires, :string, null: false)
      add(:id, :uuid, null: false, primary_key: true)
      timestamps()
    end
  end

  def(down) do
    []
  end
end