defmodule GraphismWeb.Schema do
  use Graphism

  entity :superUser do
    attribute(:id, :id)
    attribute(:email, :string, unique: true)
    attribute(:first, :string)
    attribute(:last, :string)
    attribute(:lang, :string)
    attribute(:verified, :boolean)

    relation(:roles, :has_many, :role)
    # has_many(:roles, :role)
  end

  entity :role do
    attribute(:id, :id)
    attribute(:name, :string, unique: true)
    relation(:permissions, :has_many, :permissions)
  end

  entity :permission do
    attribute(:id, :id)
    attribute(:name, :string, unique: true)
  end
end
