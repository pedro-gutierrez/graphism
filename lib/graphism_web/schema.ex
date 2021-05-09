defmodule GraphismWeb.Schema do
  use Graphism,
    repo: Graphism.Repo

  entity :super_user do
    attribute(:id, :id)
    attribute(:email, :string)
    attribute(:first, :string)
    attribute(:last, :string)
    attribute(:lang, :string)
    attribute(:verified, :boolean)

    has_many(:super_user_roles, as: :roles)
  end

  entity :super_user_role do
    attribute(:id, :id)
    belongs_to(:super_user)
    has_one(:role)
  end

  entity :role do
    attribute(:id, :id)
    attribute(:name, :string, one_of: [:admin, :user], default: :user, unique: true)
    has_many(:permissions)
  end

  entity :permission do
    attribute(:id, :id)
    attribute(:name, :string, unique: true)
  end

  entity :token do
    attribute(:id, :id)
    attribute(:expires, :string)
  end
end
