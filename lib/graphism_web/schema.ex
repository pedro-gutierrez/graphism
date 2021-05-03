defmodule GraphismWeb.Schema do
  use Graphism

  entity :superUser do
    attribute(:id, :id)
    attribute(:email, :string, unique: true)
    attribute(:first, :string)
    attribute(:last, :string)
    attribute(:lang, :string)
    attribute(:verified, :boolean)

    has_many(:roles)
  end

  entity :role do
    attribute(:id, :id)
    attribute(:name, :string, unique: true)
    has_many(:permissions)
  end

  entity :permission do
    attribute(:id, :id)
    attribute(:name, :string, unique: true)
  end
end
