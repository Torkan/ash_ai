defmodule AshAi.Changes.Vectorize do
  use Ash.Resource.Change

  def change(changeset, opts, context) do
    {embedding_model, vector_opts} =
      AshAi.Info.vectorize_embedding_model!(changeset.resource)

    attrs =
      AshAi.Info.vectorize_attributes!(changeset.resource)

    name = AshAi.Info.vectorize_full_text_name!(changeset.resource)

    attrs =
      AshAi.Info.vectorize_attributes!(changeset.resource)

    changes =
      case AshAi.Info.vectorize_full_text_text(changeset.resource) do
        {:ok, fun} ->
          used_attrs =
            case AshAi.Info.vectorize_full_text_used_attributes(changeset.resource) do
              {:ok, attrs} -> attrs
              _ -> nil
            end

          attrs ++
            [{:full_text, name, used_attrs, fun}]

        _ ->
          attrs
      end
      |> Enum.flat_map(fn
        {source, dest} ->
          text = Map.get(changeset.data, source)
          [{dest, text}]

        {:full_text, name, _used_attrs, fun} ->
          text = fun.(changeset.data)
          [{name, text}]
      end)

    strings = Enum.map(changes, &elem(&1, 1))

    case embedding_model.generate(strings, vector_opts) do
      {:ok, vectors} ->
        changes =
          Enum.zip_with(changes, vectors, fn {k, _}, r ->
            {k, r}
          end)

        Ash.Changeset.change_attributes(changeset, changes)

      {:error, error} ->
        fields = Enum.map(changes, fn {field, _} -> field end)
        Ash.Changeset.add_error(changeset, fields: fields, message: "Error while vectorizing")
    end
  end

  def atomic(changeset, opts, context) do
    {:ok, change(changeset, opts, context)}
  end
end
