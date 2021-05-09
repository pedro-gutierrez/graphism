defmodule Graphism do
  @moduledoc """
  Graphism keeps the contexts that define your domain
  and business logic.

  Contexts are also responsible for managing your data, regardless
  if it comes from the database, an external API or others.
  """

  require Logger

  defmacro __using__(opts \\ []) do
    repo = opts[:repo]

    unless repo do
      raise "Please specify a repo module when using Graphism"
    end

    Module.register_attribute(__CALLER__.module, :schema,
      accumulate: true,
      persist: true
    )

    Module.register_attribute(__CALLER__.module, :repo,
      accumulate: false,
      persist: true
    )

    Module.put_attribute(__CALLER__.module, :repo, opts[:repo])

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

    repo =
      __CALLER__.module
      |> Module.get_attribute(:repo)

    schema_fun =
      quote do
        def schema do
          unquote(schema)
        end
      end

    schema_modules =
      Enum.map(schema, fn e ->
        schema_module(e, schema, caller: __CALLER__)
      end)

    api_modules =
      Enum.map(schema, fn e ->
        api_module(e, schema, repo: repo, caller: __CALLER__)
      end)

    resolver_modules =
      Enum.map(schema, fn e ->
        resolver_module(e, schema, caller: __CALLER__)
      end)

    enums =
      Enum.map(schema, fn e ->
        graphql_enum(e, schema)
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

    List.flatten([
      schema_fun,
      schema_modules,
      api_modules,
      resolver_modules,
      enums,
      objects,
      queries,
      mutations
    ])
  end

  defmacro entity(name, _attrs \\ [], do: block) do
    attrs = attributes_from(block)
    rels = relations_from(block)

    entity =
      [name: name, attributes: attrs, relations: rels, enums: []]
      |> with_plural()
      |> with_schema_module()
      |> with_api_module()
      |> with_resolver_module()
      |> with_enums()

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
    module_name(entity, :schema_module)
  end

  defp with_resolver_module(entity) do
    module_name(entity, :resolver_module, :resolver)
  end

  defp with_api_module(entity) do
    module_name(entity, :api_module, :api)
  end

  defp module_name(entity, name, suffix \\ nil) do
    module_name =
      [entity[:name], suffix]
      |> Enum.reject(fn part -> part == nil end)
      |> Enum.map(&Atom.to_string(&1))
      |> Enum.map(&Inflex.camelize(&1))
      |> Module.concat()

    Keyword.put(
      entity,
      name,
      module_name
    )
  end

  # Inspect attributes and extract enum types from those attributes
  # that have a defined set of possible values
  defp with_enums(entity) do
    enums =
      entity[:attributes]
      |> Enum.filter(fn attr -> attr[:opts][:one_of] end)
      |> Enum.reduce([], fn attr, enums ->
        enum_name = enum_name(entity, attr)
        values = attr[:opts][:one_of]
        [[name: enum_name, values: values] | enums]
      end)

    Keyword.put(entity, :enums, enums)
  end

  defp enum_name(e, attr) do
    String.to_atom("#{e[:name]}_#{attr[:name]}s")
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
  end

  def with_display_name(e) do
    display_name = display_name(e[:name])

    plural_display_name = display_name(e[:plural])

    e
    |> Keyword.put(:display_name, display_name)
    |> Keyword.put(:plural_display_name, plural_display_name)
  end

  defp display_name(name) when is_atom(name) do
    name
    |> Atom.to_string()
    |> Inflex.camelize()
    |> :string.titlecase()
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

  defp schema_module(e, _schema, _opts) do
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
                Ecto.Schema.field(unquote(attr[:name]), unquote(attr[:kind]))
              end
            end)
          end

          timestamps()
        end
      end
    end
  end

  defp resolver_module(e, schema, _) do
    api_module = e[:api_module]

    ast =
      quote do
        defmodule unquote(e[:resolver_module]) do
          def query_all(_, _, _) do
            {:ok, unquote(api_module).list()}
          end

          def query_by_id(_, %{id: id}, _) do
            unquote(api_module).get(id)
          end

          unquote_splicing(
            e[:attributes]
            |> Enum.filter(fn attr -> attr[:opts][:unique] end)
            |> Enum.map(fn attr ->
              quote do
                def unquote(query_function_for(attr))(
                      _,
                      %{unquote(attr[:name]) => arg},
                      _
                    ) do
                  unquote(api_module).unquote(api_get_function_for(attr))(arg)
                end
              end
            end)
          )

          unquote_splicing(
            e[:relations]
            |> Enum.filter(fn rel -> rel[:kind] == :belongs_to end)
            |> Enum.map(fn rel ->
              quote do
                def unquote(query_function_for(rel))(_, %{unquote(rel[:name]) => arg}, _) do
                  {:ok, unquote(api_module).unquote(api_list_function_for(rel))(arg)}
                end
              end
            end)
          )

          def create(_, args, _) do
            unquote(
              case Enum.filter(e[:relations], fn rel -> rel[:kind] == :belongs_to end) do
                [] ->
                  quote do
                    unquote(api_module).create(args)
                  end

                rels ->
                  quote do
                    with unquote_splicing(
                           rels
                           |> Enum.map(fn rel ->
                             parent_var = Macro.var(rel[:name], nil)
                             target = find_entity!(schema, rel[:target])

                             quote do
                               {:ok, unquote(parent_var)} <-
                                 unquote(target[:api_module]).get(args.unquote(rel[:name]))
                             end
                           end)
                         ) do
                      args = Map.drop(args, unquote(Enum.map(rels, fn rel -> rel[:name] end)))

                      unquote(api_module).create(
                        unquote_splicing(
                          Enum.map(rels, fn rel ->
                            Macro.var(rel[:name], nil)
                          end)
                        ),
                        args
                      )
                    end
                  end
              end
            )
          end

          def update(_, %{id: id} = args, _) do
            with {:ok, entity} <- unquote(api_module).get(id) do
              args = Map.drop(args, [:id])

              unquote(
                case Enum.filter(e[:relations], fn rel -> rel[:kind] == :belongs_to end) do
                  [] ->
                    quote do
                      unquote(api_module).update(entity, args)
                    end

                  rels ->
                    quote do
                      with unquote_splicing(
                             rels
                             |> Enum.map(fn rel ->
                               parent_var = Macro.var(rel[:name], nil)
                               target = find_entity!(schema, rel[:target])

                               quote do
                                 {:ok, unquote(parent_var)} <-
                                   unquote(target[:api_module]).get(args.unquote(rel[:name]))
                               end
                             end)
                           ) do
                        args = Map.drop(args, unquote(Enum.map(rels, fn rel -> rel[:name] end)))

                        unquote(api_module).update(
                          unquote_splicing(
                            Enum.map(rels, fn rel ->
                              Macro.var(rel[:name], nil)
                            end)
                          ),
                          entity,
                          args
                        )
                      end
                    end
                end
              )
            end
          end

          def delete(_, %{id: id}, _) do
            with {:ok, entity} <- unquote(api_module).get(id) do
              unquote(api_module).delete(entity)
            end
          end
        end
      end

    mod = ast |> Macro.to_string() |> Code.format_string!()
    File.write!("/Users/pedrogutierrez/Desktop/#{e[:name]}.ex", mod)
    ast
  end

  defp api_module(e, _, opts) do
    schema_module = e[:schema_module]
    repo_module = opts[:repo]

    quote do
      defmodule unquote(e[:api_module]) do
        def list do
          unquote(schema_module)
          |> unquote(repo_module).all()
        end

        def create(attrs) do
          IO.inspect(create: attrs)
          {:ok, %{}}
        end

        def update(attrs) do
          IO.inspect(update: attrs)
          {:ok, %{}}
        end

        def delete(attrs) do
          IO.inspect(delete: attrs)
          {:ok, %{}}
        end
      end
    end
  end

  defp find_entity!(schema, name) do
    case Enum.filter(schema, fn e ->
           name == e[:name]
         end) do
      [] ->
        raise "Could not resolve entity #{name}: #{
                inspect(Enum.map(schema, fn e -> e[:name] end))
              }"

      [e] ->
        e
    end
  end

  defp query_function_for(field) do
    String.to_atom("query_by_#{field[:name]}")
  end

  defp api_get_function_for(field) do
    String.to_atom("get_by_#{field[:name]}")
  end

  defp api_list_function_for(field) do
    String.to_atom("list_by_#{field[:name]}")
  end

  defp graphql_object(e, _schema) do
    quote do
      object unquote(e[:name]) do
        unquote do
          # Add a field for each attribute
          Enum.map(e[:attributes], fn attr ->
            # determine the kind for this field, depending
            # on whether it is an enum or not
            kind =
              case attr[:opts][:one_of] do
                nil ->
                  # it is not an enum, so we use its defined type
                  attr[:kind]

                [_ | _] ->
                  # use the name of the enum as the type
                  enum_name(e, attr)
              end

            quote do
              field unquote(attr[:name]), unquote(kind)
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

  defp graphql_enum(e, _) do
    Enum.map(e[:enums], fn enum ->
      quote do
        enum(unquote(enum[:name]), values: unquote(enum[:values]))
      end
    end)
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
        resolve(&unquote(e[:resolver_module]).query_all/3)
      end
    end
  end

  defp graphql_query_find_by_id(e, _schema) do
    quote do
      @desc "Find a single " <> unquote("#{e[:display_name]}") <> " given its unique id"
      field unquote(String.to_atom("#{e[:name]}_by_id")),
            unquote(e[:name]) do
        arg(:id, non_null(:id))
        resolve(&unquote(e[:resolver_module]).query_by_id/3)
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
          arg(unquote(attr[:name]), non_null(unquote(attr[:kind])))

          resolve(&(unquote(e[:resolver_module]).unquote(query_function_for(attr)) / 3))
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
          arg(unquote(rel[:name]), non_null(:id))

          resolve(&(unquote(e[:resolver_module]).unquote(query_function_for(rel)) / 3))
        end
      end
    end)
  end

  defp graphql_mutations(e, schema) do
    [
      graphql_create_mutation(e, schema),
      graphql_update_mutation(e, schema),
      graphql_delete_mutation(e, schema)
    ]
  end

  defp graphql_create_mutation(e, _schema) do
    mutation_name = String.to_atom("create_#{e[:name]}")

    quote do
      @desc "Create a new " <> unquote("#{e[:display_name]}")
      field unquote(mutation_name), non_null(unquote(e[:name])) do
        unquote(
          Enum.map(e[:attributes], fn attr ->
            quote do
              arg(unquote(attr[:name]), non_null(unquote(attr[:kind])))
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

        resolve(&unquote(e[:resolver_module]).create/3)
      end
    end
  end

  defp graphql_update_mutation(e, _schema) do
    mutation_name = String.to_atom("update_#{e[:name]}")

    quote do
      @desc "Update an existing " <> unquote("#{e[:display_name]}")
      field unquote(mutation_name), non_null(unquote(e[:name])) do
        unquote(
          Enum.map(e[:attributes], fn attr ->
            quote do
              arg(unquote(attr[:name]), non_null(unquote(attr[:kind])))
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

        resolve(&unquote(e[:resolver_module]).update/3)
      end
    end
  end

  defp graphql_delete_mutation(e, _schema) do
    mutation_name = String.to_atom("delete_#{e[:name]}")

    quote do
      @desc "Delete an existing " <> unquote("#{e[:display_name]}")
      field unquote(mutation_name), unquote(e[:name]) do
        arg(:id, non_null(:id))
        resolve(&unquote(e[:resolver_module]).delete/3)
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

  defp attribute([name, kind]), do: [name: name, kind: kind, opts: []]
  defp attribute([name, kind, opts]), do: [name: name, kind: kind, opts: opts]

  defp relations_from({:__block__, [], attrs}) do
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
