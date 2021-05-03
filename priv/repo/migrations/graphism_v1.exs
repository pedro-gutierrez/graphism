defmodule(Graphism.Migration.V1) do
  use(Ecto.Migration)

  def(up) do
    create(table(:permissions, primary_key: false)) do
      add(:id, :id)
      add(:name, :string)
    end

    create(table(:roles, primary_key: false)) do
      add(:id, :id)
      add(:name, :string)
    end

    create(table(:super_users, primary_key: false)) do
      add(:email, :string)
      add(:first, :string)
      add(:id, :id)
      add(:lang, :string)
      add(:last, :string)
      add(:verified, :boolean)
    end
  end

  def(down) do
    []
  end
end