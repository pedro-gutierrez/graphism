defmodule Graphism do
  @moduledoc """
  Graphism keeps the contexts that define your domain
  and business logic.

  Contexts are also responsible for managing your data, regardless
  if it comes from the database, an external API or others.
  """

  require Logger

  defmacro __using__(_opts \\ []) do
    Module.register_attribute(__CALLER__.module, :schema,
      accumulate: true,
      persist: true
    )

    quote do
      @before_compile unquote(__MODULE__)
      import unquote(__MODULE__), only: :macros
      use Absinthe.Schema
    end
  end

  defmacro __before_compile__(_) do
    schema =
      __CALLER__.module
      |> Module.get_attribute(:schema)
      |> resolve()

    schema_fun =
      quote do
        def schema do
          unquote(schema)
        end
      end

    api_modules =
      Enum.map(schema, fn e ->
        api_module(e, schema, caller: __CALLER__)
      end)

    objects =
      Enum.map(schema, fn e ->
        graphql_object(e, schema)
      end)

    queries =
      quote do
        query do
          unquote do
            Enum.flat_map(schema, fn e ->
              graphql_queries(e, schema)
            end)
          end
        end
      end

    mutations =
      quote do
        mutation do
          unquote do
            Enum.flat_map(schema, fn e ->
              graphql_mutations(e, schema)
            end)
          end
        end
      end

    [schema_fun, api_modules, objects, queries, mutations]
  end

  defmacro entity(name, _attrs \\ [], do: block) do
    attrs = attributes_from(block)
    rels = relations_from(block)

    entity =
      [name: name, attributes: attrs, relations: rels]
      |> with_plural()
      |> with_schema_module()

    Module.put_attribute(__CALLER__.module, :schema, entity)

    block
  end

  defmacro attribute(_name, _type, _attrs \\ []) do
  end

  defmacro has_many(_name, _opts \\ []) do
  end

  defmacro has_one(_name, _opts \\ []) do
  end

  defmacro belongs_to(_name, _opts \\ []) do
  end

  defp with_plural(entity) do
    case entity[:plural] do
      nil ->
        Keyword.put(entity, :plural, String.to_atom("#{entity[:name]}s"))

      _ ->
        entity
    end
  end

  defp with_schema_module(entity) do
    module_name =
      [entity[:name], :schema]
      |> Enum.map(&Atom.to_string(&1))
      |> Enum.map(&String.capitalize(&1))
      |> Module.concat()

    Keyword.put(
      entity,
      :schema_module,
      module_name
    )
  end

  # Resolves the given schema, by inspecting links between entities
  # and making sure everything is consistent
  defp resolve(schema) do
    # Index plurals so that we can later resolve relations
    plurals =
      Enum.reduce(schema, %{}, fn e, index ->
        Map.put(index, e[:plural], e[:name])
      end)

    # Index entities by name
    index =
      Enum.reduce(schema, %{}, fn e, index ->
        Map.put(index, e[:name], e)
      end)

    schema
    |> Enum.map(fn e ->
      e
      |> with_display_name()
      |> with_relations!(index, plurals)
    end)
    |> IO.inspect()
  end

  def with_display_name(e) do
    display_name =
      e[:name]
      |> Atom.to_string()
      |> Recase.to_camel()
      |> :string.titlecase()

    plural_display_name =
      e[:plural]
      |> Atom.to_string()
      |> Recase.to_camel()
      |> :string.titlecase()

    e
    |> Keyword.put(:display_name, display_name)
    |> Keyword.put(:plural_display_name, plural_display_name)
  end

  # Ensure all relations are properly formed. 
  # This function will raise an error if the target entity
  # for a relation cannot be found
  defp with_relations!(e, index, plurals) do
    relations =
      e[:relations]
      |> Enum.map(fn rel ->
        case rel[:kind] do
          :has_many ->
            target = plurals[rel[:name]]

            unless target do
              raise "Entity #{e[:name]} has relation #{rel[:name]} of unknown type: #{
                      inspect(plurals)
                    }"
            end

            rel
            |> Keyword.put(:target, target)
            |> Keyword.put(:name, rel[:opts][:as] || rel[:name])

          _ ->
            target = index[rel[:name]]

            unless target do
              raise "Entity #{e[:name]} has relation #{rel[:name]} of unknown type: #{
                      inspect(Map.keys(index))
                    }"
            end

            rel
            |> Keyword.put(:target, target[:name])
            |> Keyword.put(:name, rel[:opts][:as] || rel[:name])
        end
      end)

    Keyword.put(e, :relations, relations)
  end

  defp api_module(e, _schema, _opts) do
    quote do
      defmodule unquote(e[:schema_module]) do
        use Ecto.Schema
        import Ecto.Changeset

        schema unquote("#{e[:plural]}") do
          unquote do
            e[:attributes]
            |> Enum.reject(fn attr -> attr[:name] == :id end)
            |> Enum.map(fn attr ->
              quote do
                Ecto.Schema.field(unquote(attr[:name]), unquote(attr[:type]))
              end
            end)
          end

          timestamps()
        end
      end
    end
  end

  defp graphql_object(e, _schema) do
    quote do
      object unquote(e[:name]) do
        unquote do
          # Add a field for each attribute
          Enum.map(e[:attributes], fn attr ->
            quote do
              field unquote(attr[:name]), unquote(attr[:type])
            end
          end) ++
            Enum.map(e[:relations], fn rel ->
              # Add a field for each relation
              quote do
                field unquote(rel[:name]),
                      unquote(
                        case rel[:kind] do
                          :has_many ->
                            quote do
                              list_of(unquote(rel[:target]))
                            end

                          _ ->
                            quote do
                              non_null(unquote(rel[:target]))
                            end
                        end
                      )
              end
            end)
        end
      end
    end
  end

  defp graphql_queries(e, schema) do
    List.flatten([
      graphql_query_list_all(e, schema),
      graphql_query_find_by_id(e, schema),
      graphql_query_find_by_unique_fields(e, schema),
      graphql_query_find_by_parent_types(e, schema)
    ])
  end

  defp graphql_query_list_all(e, _schema) do
    quote do
      @desc "List all " <> unquote("#{e[:plural_display_name]}")
      field unquote(e[:plural]), list_of(unquote(e[:name])) do
        resolve(fn _, _, _ ->
          {:ok, []}
        end)
      end
    end
  end

  defp graphql_query_find_by_id(e, _schema) do
    quote do
      @desc "Find a single " <> unquote("#{e[:display_name]}") <> " given its unique id"
      field unquote(String.to_atom("#{e[:name]}_by_id")),
            unquote(e[:name]) do
        resolve(fn _, _, _ ->
          {:ok, []}
        end)
      end
    end
  end

  defp graphql_query_find_by_unique_fields(e, _schema) do
    e[:attributes]
    |> Enum.filter(fn attr -> Keyword.get(attr[:opts], :unique) end)
    |> Enum.map(fn attr ->
      quote do
        @desc "Find a single " <>
                unquote("#{e[:display_name]}") <>
                " given its unique " <> unquote("#{attr[:name]}")
        field unquote(String.to_atom("#{e[:name]}_by_#{attr[:name]}")),
              unquote(e[:name]) do
          resolve(fn _, _, _ ->
            {:ok, []}
          end)
        end
      end
    end)
  end

  defp graphql_query_find_by_parent_types(e, _schema) do
    e[:relations]
    |> Enum.filter(fn rel -> :belongs_to == rel[:kind] end)
    |> Enum.map(fn rel ->
      quote do
        @desc "Find all " <>
                unquote("#{e[:plural_display_name]}") <>
                " given their parent " <> unquote("#{rel[:target]}")
        field unquote(String.to_atom("#{e[:plural]}_by_#{rel[:name]}")),
              list_of(unquote(e[:name])) do
          resolve(fn _, _, _ ->
            {:ok, []}
          end)
        end
      end
    end)
  end

  defp graphql_mutations(e, schema) do
    List.flatten([
      graphql_create_mutation(e, schema)
    ])
  end

  defp graphql_create_mutation(e, _schema) do
    mutation_name = String.to_atom("create_#{e[:name]}")

    quote do
      @desc "Create a new " <> unquote("#{e[:display_name]}")
      field unquote(mutation_name), non_null(unquote(e[:name])) do
        unquote(
          Enum.map(e[:attributes], fn attr ->
            quote do
              arg(unquote(attr[:name]), non_null(unquote(attr[:type])))
            end
          end) ++
            (e[:relations]
             |> Enum.filter(fn rel -> :belongs_to == rel[:kind] || :has_one == rel[:kind] end)
             |> Enum.map(fn rel ->
               quote do
                 arg(unquote(rel[:name]), non_null(:id))
               end
             end))
        )

        resolve(fn _, _, _ ->
          {:ok, %{}}
        end)
      end
    end
  end

  defp attributes_from({:__block__, [], attrs}) do
    attrs
    |> Enum.map(fn
      {:attribute, _, attr} ->
        attribute(attr)

      _ ->
        nil
    end)
    |> Enum.reject(fn attr -> attr == nil end)
  end

  defp attribute([name, type]), do: [name: name, type: type, opts: []]
  defp attribute([name, type, opts]), do: [name: name, type: type, opts: opts]

  defp relations_from({:__block__, [], attrs}) do
    IO.inspect(attrs: attrs)

    attrs
    |> Enum.map(fn
      {:has_many, _, [name]} ->
        [name: name, kind: :has_many, opts: []]

      {:has_many, _, [name, opts]} ->
        [name: name, kind: :has_many, opts: opts]

      {:has_one, _, [name]} ->
        [name: name, kind: :has_one, opts: []]

      {:has_one, _, [name, opts]} ->
        [name: name, kind: :has_one, opts: opts]

      {:belongs_to, _, [name]} ->
        [name: name, kind: :belongs_to, opts: []]

      {:belongs_to, _, [name, opts]} ->
        [name: name, kind: :belongs_to, opts: opts]

      _ ->
        nil
    end)
    |> Enum.reject(fn rel -> rel == nil end)
  end
end
