defmodule Mix.Tasks.AshAi.Gen.Chat.Docs do
  @moduledoc false

  def short_doc do
    "Generates the resources and views for a conversational UI backed by `ash_postgres` and `ash_oban`"
  end

  def example do
    "mix ash_ai.gen.chat --user Your.User.Resource --live"
  end

  def long_doc do
    """
    #{short_doc()}

    Creates a `YourApp.Chat.Conversation` and a `YourApp.Chat.Message` resource, backed by postgres and ash_oban.

    ## Example

    ```bash
    #{example()}
    ```

    ## Options

    * `--user` - The user resource.
    * `--domain` - The domain to place the resources in.
    * `--extend` - Extensions to apply to the generated resources, passed through to `mix ash.gen.resource`.
    """
  end
end

if Code.ensure_loaded?(Igniter) do
  defmodule Mix.Tasks.AshAi.Gen.Chat do
    @shortdoc "#{__MODULE__.Docs.short_doc()}"

    @moduledoc __MODULE__.Docs.long_doc()

    use Igniter.Mix.Task

    @impl Igniter.Mix.Task
    def info(_argv, _composing_task) do
      %Igniter.Mix.Task.Info{
        group: :ash_ai,
        example: __MODULE__.Docs.example(),
        schema: [user: :string, domain: :string, extend: :string, live: :boolean, yes: :boolean],
        defaults: [live: false, yes: false]
      }
    end

    @impl Igniter.Mix.Task
    def igniter(igniter) do
      {igniter, user} = user_module(igniter)

      chat =
        if igniter.args.options[:domain] do
          Igniter.Project.Module.parse(igniter.arg.options[:domain])
        else
          Igniter.Project.Module.module_name(igniter, "Chat")
        end

      conversation = Module.concat([chat, Conversation])
      message = Module.concat([chat, Message])
      otp_app = Igniter.Project.Application.app_name(igniter)

      igniter
      |> ensure_deps()
      |> configure()
      |> create_conversation(conversation, message, user)
      |> create_message(chat, conversation, message, otp_app)
      |> add_chat_live(chat, conversation, message)
      |> add_code_interfaces(chat, conversation, message, user)
      |> add_triggers(message, conversation, user, otp_app)
      |> Ash.Igniter.codegen("add_ai_chat")
      |> Igniter.add_notice("""
      AshAi:

      The chat feature has been generated assuming an OpenAI setup.
      Please see LangChain's documentation on setting up other providers,
      and modify the generated code accordingly to use your desired model.
      """)
    end

    defp ensure_deps(igniter) do
      {igniter, install_ash_phoenix?} =
        if Igniter.Project.Deps.has_dep?(igniter, :ash_phoenix) do
          {igniter, false}
        else
          {Igniter.Project.Deps.add_dep(igniter, {:ash_phoenix, "~> 2.0"}), true}
        end

      {igniter, install_ash_oban?} =
        if Igniter.Project.Deps.has_dep?(igniter, :ash_oban) do
          {igniter, false}
        else
          {Igniter.Project.Deps.add_dep(igniter, {:ash_oban, "~> 0.4"}), true}
        end

      igniter
      |> then(fn igniter ->
        if install_ash_phoenix? || install_ash_oban? do
          if igniter.assigns[:test_mode?] do
            igniter
          else
            Igniter.apply_and_fetch_dependencies(igniter, yes: igniter.args.options[:yes])
          end
        else
          igniter
        end
      end)
      |> then(fn igniter ->
        if install_ash_phoenix? do
          Igniter.compose_task(igniter, "ash_phoenix.install")
        else
          igniter
        end
      end)
      |> then(fn igniter ->
        if install_ash_oban? do
          igniter
          |> Igniter.compose_task("oban.install")
          |> Igniter.compose_task("ash_oban.install")
        else
          igniter
        end
      end)
    end

    defp create_conversation(igniter, conversation, message, user) do
      generate_name =
        Module.concat([conversation, Changes, GenerateName])

      igniter
      |> Igniter.compose_task(
        "ash.gen.resource",
        [
          inspect(conversation),
          "--attribute",
          "title:string:public",
          "--uuid-v7-primary-key",
          "id",
          "--default-actions",
          "read,destroy",
          "--relationship",
          "has_many:messages:#{inspect(message)}:public",
          "--timestamps",
          "--extend",
          "postgres,AshOban",
          "--extend",
          igniter.args.options[:extend] || ""
        ] ++
          user_relationship(user)
      )
      |> Ash.Resource.Igniter.add_new_action(conversation, :create, """
      create :create do
        accept [:title]
        change relate_actor(:user)
      end
      """)
      |> Ash.Resource.Igniter.add_new_calculation(conversation, :needs_name, """
      calculate :needs_name, :boolean do
        calculation expr(count(messages) > 3 or (count(messages) > 1 and inserted_at < ago(10, :minute)))
      end
      """)
      |> Ash.Resource.Igniter.add_new_action(conversation, :generate_name, """
      update :generate_name do
        accept []
        transaction? false
        require_atomic? false
        change #{inspect(generate_name)}
      end
      """)
      |> Igniter.Project.Module.create_module(generate_name, """
      use Ash.Resource.Change
      require Ash.Query

      alias LangChain.Chains.LLMChain
      alias LangChain.ChatModels.ChatOpenAI

      @impl true
      def change(changeset, _opts, context) do
        Ash.Changeset.before_transaction(changeset, fn changeset ->
          conversation = changeset.data

          messages =
            #{inspect(message)}
            |> Ash.Query.filter(conversation_id == ^conversation.id)
            |> Ash.Query.limit(3)
            |> Ash.Query.select(:text)
            |> Ash.Query.sort(inserted_at: :asc)
            |> Ash.list!(:text)

          system_prompt =
            LangChain.Message.new_system!(\"""
            Provide a short name for the current conversation.
            2-8 words, preferring more succint names.
            RESPOND WITH ONLY THE NEW CONVERSATION NAME.
            \""")

          user_messages =
            Enum.map(messages, &LangChain.Message.new_user!/1)

          %{
            llm: ChatOpenAI.new!(%{model: "gpt-4o", custom_context: Map.new(Ash.Context.to_opts(context))}),
            verbose?: true
          }
          |> LLMChain.new!()
          |> LLMChain.add_messages([system_prompt | user_messages])
          |> LLMChain.run(mode: :while_needs_response)
          |> case do
            {:ok,
            %LangChain.Chains.LLMChain{
              last_message: %{content: content}
            }} ->
              Ash.Changeset.force_change_attribute(changeset, :title, content)

            {:error, _, error} ->
              {:error, error}
          end
        end)
      end
      """)
      |> then(fn igniter ->
        if user do
          Ash.Resource.Igniter.add_new_action(igniter, conversation, :my_conversations, """
          read :my_conversations do
            filter expr(user_id == ^actor(:id))
          end
          """)
        else
          igniter
        end
      end)
    end

    defp create_message(igniter, chat, conversation, message, otp_app) do
      create_conversation_if_not_provided =
        Module.concat([message, Changes, CreateConversationIfNotProvided])

      respond = Module.concat([message, Changes, Respond])

      source = Module.concat([message, Types, Source])

      igniter
      |> Igniter.compose_task("ash.gen.enum", [inspect(source), "agent,user"])
      |> Igniter.compose_task(
        "ash.gen.resource",
        [
          inspect(message),
          "--default-actions",
          "read,destroy",
          "--relationship",
          "belongs_to:conversation:#{inspect(conversation)}:public:required",
          "--relationship",
          "belongs_to:response_to:__MODULE__:public",
          "--timestamps",
          "--extend",
          "postgres,AshOban",
          "--extend",
          igniter.args.options[:extend] || ""
        ]
      )
      |> Ash.Resource.Igniter.add_new_attribute(message, :id, """
      uuid_v7_primary_key :id, writable?: true
      """)
      |> Ash.Resource.Igniter.add_new_attribute(message, :text, """
      attribute :text, :string do
        constraints allow_empty?: true, trim?: false
        public? true
        allow_nil? false
      end
      """)
      |> Ash.Resource.Igniter.add_new_attribute(message, :source, """
      attribute :source, #{inspect(source)} do
        allow_nil? false
        public? true
        default :user
      end
      """)
      |> Ash.Resource.Igniter.add_new_attribute(message, :complete, """
      attribute :complete, :boolean do
        allow_nil? false
        default true
      end
      """)
      |> Ash.Resource.Igniter.add_new_relationship(message, :response, """
      has_one :response, __MODULE__ do
        public? true
        destination_attribute :response_to_id
      end
      """)
      |> Igniter.Project.Module.create_module(
        create_conversation_if_not_provided,
        """
        use Ash.Resource.Change

        @impl true
        def change(changeset, _opts, context) do
          if changeset.arguments[:conversation_id] do
            Ash.Changeset.force_change_attribute(
              changeset,
              :conversation_id,
              changeset.arguments.conversation_id
            )
          else
            Ash.Changeset.before_action(changeset, fn changeset ->
              conversation = #{inspect(chat)}.create_conversation!(Ash.Context.to_opts(context))

              Ash.Changeset.force_change_attribute(changeset, :conversation_id, conversation.id)
            end)
          end
        end
        """
      )
      |> Ash.Resource.Igniter.add_new_action(message, :for_conversation, """
      read :for_conversation do
        pagination keyset?: true, required?: false
        argument :conversation_id, :uuid, allow_nil?: false

        prepare build(default_sort: [inserted_at: :desc])
        filter expr(conversation_id == ^arg(:conversation_id))
      end
      """)
      |> Ash.Resource.Igniter.add_new_action(message, :create, """
      create :create do
        accept [:text]
        argument :conversation_id, :uuid do
          public? false
        end

        change #{inspect(create_conversation_if_not_provided)}
        change run_oban_trigger(:respond)
      end
      """)
      |> Ash.Resource.Igniter.add_new_action(message, :respond, """
      update :respond do
        accept []
        require_atomic? false
        transaction? false
        change #{inspect(respond)}
      end
      """)
      |> Ash.Resource.Igniter.add_new_action(message, :upsert_response, """
      create :upsert_response do
        upsert? true
        accept [:id, :response_to_id, :conversation_id]
        argument :complete, :boolean, default: false
        argument :text, :string, allow_nil?: false, constraints: [trim?: false]

        validate argument_does_not_equal?(:text, "")

        # if updating
        #   if complete, set the text to the provided text
        #   if streaming still, add the text to the provided text
        change atomic_update(:text, {:atomic, expr(
          if ^arg(:complete) do
            ^arg(:text)
          else
            ^atomic_ref(:text) <> ^arg(:text)
          end
        )})

        # if creating, set the text attribute to the provided text
        change set_attribute(:text, arg(:text))
        change set_attribute(:complete, arg(:complete))
        change set_attribute(:source, :agent)

        # on update, only set complete to its new value
        upsert_fields [:complete]
      end
      """)
      |> Ash.Resource.Igniter.add_new_calculation(message, :needs_response, """
      calculate :needs_response, :boolean do
        calculation expr(source == :user and not exists(response))
      end
      """)
      |> Igniter.Project.Module.create_module(respond, """
      use Ash.Resource.Change
      require Ash.Query

      alias LangChain.Chains.LLMChain
      alias LangChain.ChatModels.ChatOpenAI

      @impl true
      def change(changeset, _opts, context) do
        Ash.Changeset.before_transaction(changeset, fn changeset ->
          message = changeset.data

          messages =
            #{inspect(message)}
            |> Ash.Query.filter(conversation_id == ^message.conversation_id)
            |> Ash.Query.filter(id != ^message.id)
            |> Ash.Query.limit(10)
            |> Ash.Query.select(:text)
            |> Ash.Query.sort(inserted_at: :desc)
            |> Ash.list!(:text)
            |> Enum.concat([message.text])

          system_prompt =
            LangChain.Message.new_system!(\"""
            You are a helpful chat bot.
            \""")

          user_messages =
            Enum.map(messages, &LangChain.Message.new_user!/1)

          new_message_id = Ash.UUID.generate()

          %{
            llm: ChatOpenAI.new!(%{model: "gpt-4o", stream: true, custom_context: Map.new(Ash.Context.to_opts(context))})
          }
          |> LLMChain.new!()
          |> LLMChain.add_messages([system_prompt | user_messages])
          # add the names of tools you want available in your conversation here.
          # i.e tools: [:lookup_weather]
          |> AshAi.setup_ash_ai(otp_app: :#{otp_app}, tools: [], actor: context.actor)
          |> LLMChain.add_callback(%{
            on_llm_new_delta: fn  _model, data ->
              if data.content && data.content != "" do
                #{inspect(message)}
                |> Ash.Changeset.for_create(:upsert_response, %{
                  id: new_message_id,
                  response_to_id: message.id,
                  conversation_id: message.conversation_id,
                  text: data.content
                }, actor: %AshAi{})
                |> Ash.create!()
              end
            end,
            on_message_processed: fn _chain, data ->
              if data.content && data.content != "" do
                #{inspect(message)}
                |> Ash.Changeset.for_create(:upsert_response, %{
                  id: new_message_id,
                  response_to_id: message.id,
                  conversation_id: message.conversation_id,
                  text: data.content,
                  complete: true
                }, actor: %AshAi{})
                |> Ash.create!()
              end
            end
          })
          |> LLMChain.run(mode: :while_needs_response)

          changeset
        end)
      end
      """)
    end

    defp set_conversation_pub_sub(igniter, conversation, endpoint) do
      igniter
      |> Spark.Igniter.add_extension(conversation, Ash.Resource, :notifiers, Ash.Notifier.PubSub)
      |> Igniter.Project.Module.find_and_update_module!(conversation, fn zipper ->
        with {:ok, zipper} <- ensure_pub_sub(zipper, endpoint),
             {:ok, zipper} <- ensure_prefix(zipper),
             {:ok, zipper} <-
               add_new_publish(zipper, :create, :publish_all, """
               publish_all :create, ["conversations", :user_id] do
                 transform &(&1.data)
               end
               """),
             {:ok, zipper} <-
               add_new_publish(zipper, :update, :publish_all, """
               publish_all :update, ["conversations", :user_id] do
                 transform &(&1.data)
               end
               """) do
          {:ok, zipper}
        else
          _ ->
            {:ok, zipper}
        end
      end)
    end

    defp set_message_pub_sub(igniter, message, endpoint) do
      igniter
      |> Spark.Igniter.add_extension(message, Ash.Resource, :notifiers, Ash.Notifier.PubSub)
      |> Igniter.Project.Module.find_and_update_module!(message, fn zipper ->
        with {:ok, zipper} <- ensure_pub_sub(zipper, endpoint),
             {:ok, zipper} <- ensure_prefix(zipper),
             {:ok, zipper} <-
               add_new_publish(zipper, :create, """
                publish :create, ["messages", :conversation_id] do
                  transform fn %{data: message} ->
                    %{text: message.text, id: message.id, source: message.source}
                  end
                end
               """),
             {:ok, zipper} <-
               add_new_publish(zipper, :upsert_response, """
                publish :upsert_response, ["messages", :conversation_id] do
                  transform fn %{data: message} ->
                    %{text: message.text, id: message.id, source: message.source}
                  end
                end
               """) do
          {:ok, zipper}
        else
          _ ->
            {:ok, zipper}
        end
      end)
    end

    defp add_new_publish(zipper, name, type \\ :publish, code) do
      Igniter.Code.Common.within(zipper, fn zipper ->
        case Igniter.Code.Function.move_to_function_call_in_current_scope(
               zipper,
               type,
               [2, 3],
               &Igniter.Code.Function.argument_equals?(&1, 0, name)
             ) do
          {:ok, _} ->
            {:ok, zipper}

          :error ->
            {:ok, Igniter.Code.Common.add_code(zipper, code)}
        end
      end)
    end

    defp ensure_pub_sub(zipper, endpoint) do
      with {:ok, zipper} <-
             Igniter.Code.Function.move_to_function_call_in_current_scope(zipper, :pub_sub, 1),
           {:ok, zipper} <- Igniter.Code.Common.move_to_do_block(zipper) do
        {:ok, zipper}
      else
        _ ->
          zipper =
            Igniter.Code.Common.add_code(zipper, """
            pub_sub do
              module #{inspect(endpoint)}
              prefix "chat"
            end
            """)

          with {:ok, zipper} <-
                 Igniter.Code.Function.move_to_function_call_in_current_scope(zipper, :pub_sub, 1),
               {:ok, zipper} <- Igniter.Code.Common.move_to_do_block(zipper) do
            {:ok, zipper}
          else
            _ ->
              :error
          end
      end
    end

    defp ensure_prefix(zipper) do
      Igniter.Code.Common.within(zipper, fn zipper ->
        case Igniter.Code.Function.move_to_function_call_in_current_scope(zipper, :prefix, 1) do
          {:ok, _zipper} ->
            {:ok, zipper}

          :error ->
            {:ok,
             Igniter.Code.Common.add_code(zipper, """
             prefix "chat"
             """)}
        end
      end)
    end

    defp add_code_interfaces(igniter, chat, conversation, message, user) do
      igniter
      |> Spark.Igniter.add_extension(chat, Ash.Domain, :extensions, AshPhoenix)
      |> Ash.Domain.Igniter.add_new_code_interface(
        chat,
        conversation,
        :create_conversation,
        "define :create_conversation, action: :create"
      )
      |> Ash.Domain.Igniter.add_new_code_interface(
        chat,
        conversation,
        :get_conversation,
        "define :get_conversation, action: :read, get_by: [:id]"
      )
      |> Ash.Domain.Igniter.add_new_code_interface(
        chat,
        message,
        :message_history,
        """
        define :message_history,
          action: :for_conversation,
          args: [:conversation_id],
          default_options: [query: [sort: [inserted_at: :desc]]]
        """
      )
      |> Ash.Domain.Igniter.add_new_code_interface(
        chat,
        message,
        :create_message,
        "define :create_message, action: :create"
      )
      |> then(fn igniter ->
        if user do
          Ash.Domain.Igniter.add_new_code_interface(
            igniter,
            chat,
            conversation,
            :my_conversations,
            "define :my_conversations"
          )
        else
          igniter
        end
      end)
    end

    defp add_chat_live(igniter, chat, conversation, message) do
      if igniter.args.options[:live] do
        web_module = Igniter.Libs.Phoenix.web_module(igniter)
        chat_live = Igniter.Libs.Phoenix.web_module_name(igniter, "ChatLive")
        live_user_auth = Igniter.Libs.Phoenix.web_module_name(igniter, "LiveUserAuth")

        {igniter, router} =
          Igniter.Libs.Phoenix.select_router(
            igniter,
            "Which `Phoenix.Router` should be we add the chat routes to?"
          )

        if router do
          {igniter, endpoint} =
            Igniter.Libs.Phoenix.select_endpoint(
              igniter,
              router,
              "Which `Phoenix.Endpoint` should be we use for pubsub events?"
            )

          if endpoint do
            {live_user_auth_exists?, igniter} =
              Igniter.Project.Module.module_exists(igniter, live_user_auth)

            on_mount =
              if live_user_auth_exists? do
                "on_mount {#{inspect(live_user_auth)}, :live_user_required}"
              else
                "# on_mount {#{inspect(live_user_auth)}, :live_user_required}"
              end

            Igniter.Project.Module.create_module(
              igniter,
              chat_live,
              chat_live_contents(web_module, on_mount, endpoint, chat)
            )
            |> set_message_pub_sub(message, endpoint)
            |> set_conversation_pub_sub(conversation, endpoint)
            |> add_chat_live_route(chat_live, router)
          else
            Igniter.add_warning(
              igniter,
              "Could not find an endpoint for pubsub, or no endpoint was selected, liveviews have been skipped."
            )
          end
        else
          Igniter.add_warning(
            igniter,
            "Could not find a router for placing routes in, or no router was selected, liveviews have been skipped."
          )
        end
      else
        igniter
      end
    end

    defp add_chat_live_route(igniter, chat_live, router) do
      live =
        """
        live \"/chat\", #{inspect(Module.split(chat_live) |> Enum.drop(1) |> Module.concat())}
        live \"/chat/:conversation_id\", #{inspect(Module.split(chat_live) |> Enum.drop(1) |> Module.concat())}
        """

      if router do
        Igniter.Project.Module.find_and_update_module!(igniter, router, fn zipper ->
          with {:ok, zipper} <-
                 Igniter.Code.Common.move_to(
                   zipper,
                   &Igniter.Code.Function.function_call?(&1, :ash_authentication_live_session, [
                     1,
                     2,
                     3
                   ])
                 ),
               {:ok, zipper} <- Igniter.Code.Common.move_to_do_block(zipper) do
            {:ok, Igniter.Code.Common.add_code(zipper, live, placement: :before)}
          else
            :error ->
              {:warning,
               """
               AshAi: Couldn't add the chat route to `#{inspect(router)}`. Please add it manually.

                   #{live}
               """}
          end
        end)
      else
        Igniter.add_notice(
          igniter,
          """
          AshAi: Could not determine a phoenix router, could not add the chat route manually:

              #{live}
          """
        )
      end
    end

    defp configure(igniter) do
      api_key_code =
        quote do
          fn -> System.fetch_env!("OPENAI_API_KEY") end
        end

      igniter
      |> Igniter.Project.Config.configure_new(
        "runtime.exs",
        :langchain,
        [:openai_key],
        {:code, api_key_code}
      )
      |> Igniter.Project.IgniterConfig.add_extension(Igniter.Extensions.Phoenix)
    end

    defp user_relationship(nil), do: []

    defp user_relationship(user) do
      ["--relationship", "belongs_to:user:#{inspect(user)}:public:required"]
    end

    defp user_module(igniter) do
      if igniter.args.options[:user] do
        {igniter, Igniter.Project.Module.parse(igniter.args.options[:user])}
      else
        default =
          Igniter.Project.Module.module_name(igniter, "Accounts.User")

        {exists?, igniter} = Igniter.Project.Module.module_exists(igniter, default)

        if exists? do
          {igniter, default}
        else
          {igniter, nil}
        end
      end
    end

    defp add_triggers(igniter, message, conversation, user, otp_app) do
      actor_persister = Igniter.Project.Module.module_name(igniter, "AiAgentActorPersister")
      respond_worker_module_name = Module.concat([message, "Workers.Respond"])
      respond_scheduler_module_name = Module.concat([message, "Schedulers.Respond"])

      name_conversation_worker_module_name =
        Module.concat([message, "Workers.NameConversation"])

      name_conversation_scheduler_module_name =
        Module.concat([message, "Schedulers.NameConversation"])

      igniter
      |> Igniter.Project.Module.find_and_update_or_create_module(
        actor_persister,
        """
        use AshOban.ActorPersister

        def store(%#{inspect(user)}{id: id}), do: %{"type" => "user", "id" => id}

        def lookup(%{"type" => "user", "id" => id}) do
          with {:ok, user} <- Ash.get(#{inspect(user)}, id, authorize?: false) do
            # you can change the behavior of actions
            # or what your policies allow
            # using the `chat_agent?` metadata
            {:ok, Ash.Resource.set_metadata(user, %{chat_agent?: true})}
          end
        end

        # This allows you to set a default actor
        # in cases where no actor was present
        # when scheduling.
        def lookup(nil), do: {:ok, nil}
        """,
        fn zipper -> {:ok, zipper} end
      )
      |> add_new_trigger(message, :respond, """
      trigger :respond do
        actor_persister #{inspect(actor_persister)}
        action :respond
        queue :chat_responses
        lock_for_update? false
        scheduler_cron false
        worker_module_name #{inspect(respond_worker_module_name)}
        scheduler_module_name #{inspect(respond_scheduler_module_name)}
        where expr(needs_response)
      end
      """)
      |> add_new_trigger(conversation, :respond, """
      trigger :name_conversation do
        action :generate_name
        queue :conversations
        lock_for_update? false
        worker_module_name #{inspect(name_conversation_worker_module_name)}
        scheduler_module_name #{inspect(name_conversation_scheduler_module_name)}
        where expr(needs_name)
      end
      """)
      # todo: make this smarter
      |> Igniter.Project.Config.configure(
        "config.exs",
        otp_app,
        [Oban, :queues, :chat_responses, :limit],
        10
      )
      |> Igniter.Project.Config.configure(
        "config.exs",
        otp_app,
        [Oban, :queues, :conversations, :limit],
        10
      )
    end

    defp add_new_trigger(igniter, conversation, name, code) do
      apply(AshOban.Igniter, :add_new_trigger, [igniter, conversation, name, code])
    end

    defp chat_live_contents(web_module, on_mount, endpoint, chat) do
      """
      use #{web_module}, :live_view
      #{on_mount}
        def render(assigns) do
          ~H\"""
          <div class="h-screen flex overflow-hidden">
            <div class="w-1/4 border-r overflow-y-auto">
              <div class="p-4">
                <.header class="text-lg mb-4">
                  Conversations
                </.header>
                <div class="mb-4">
                  <.link
                    navigate={~p"/chat"}
                    class="w-full py-2 px-3 flex items-center justify-center rounded-md transition"
                  >
                    <span>New Chat</span>
                  </.link>
                </div>
                <ul class="space-y-2 flex flex-col-reverse" phx-update="stream" id="conversations-list">
                  <%= for {id, conversation} <- @streams.conversations do %>
                    <li id={id}>
                      <.link
                        href={~p"/chat/\#{conversation.id}"}
                        phx-click="select_conversation"
                        phx-value-id={conversation.id}
                        class={"block py-2 px-3 rounded-md truncate transition \#{if @conversation && @conversation.id == conversation.id, do: "font-medium border-l-4 border-blue-500 pl-2", else: ""}"}
                      >
                        {conversation.title || "Untitled Conversation"}
                      </.link>
                    </li>
                  <% end %>
                </ul>
              </div>
            </div>

            <div class="flex-1 flex flex-col">
              <div class="p-4 border-b">
                <.header class="text-lg">
                  {if @conversation, do: @conversation.title || "Untitled Conversation", else: "New Chat"}
                </.header>
              </div>

              <div class="flex-1 overflow-hidden flex flex-col">
                <div
                  id="message-container"
                  phx-update="stream"
                  class="flex-1 overflow-y-auto px-4 py-2 flex flex-col-reverse"
                >
                  <%= for {id, message} <- @streams.messages do %>
                    <div id={id} class="mb-4 flex">
                      <div class={"rounded-lg p-4 max-w-[80%] \#{if message.source == :user, do: "ml-auto border", else: "border"}"}>
                        {message.text}
                      </div>
                    </div>
                  <% end %>
                </div>

                <div class="p-4 border-t">
                  <.form
                    :let={form}
                    for={@message_form}
                    phx-change="validate_message"
                    phx-debounce="blur"
                    phx-submit="send_message"
                    class="flex items-center gap-2"
                  >
                    <div class="flex-1">
                      <.input
                        field={form[:text]}
                        type="text"
                        phx-mounted={JS.focus()}
                        placeholder="Type your message..."
                        class="w-full py-2 px-3 rounded-md focus:ring-2 focus:ring-blue-500"
                        autocomplete="off"
                      />
                    </div>
                    <.button type="submit" class="py-2 px-4 rounded-md transition">
                      Send
                    </.button>
                  </.form>
                </div>
              </div>
            </div>
          </div>
          \"""
        end

        def mount(_params, _session, socket) do
          #{inspect(endpoint)}.subscribe("chat:conversations:\#{socket.assigns.current_user.id}")

          socket =
            socket
            |> assign(:page_title, "Chat")
            |> stream(
              :conversations,
              #{inspect(chat)}.my_conversations!(actor: socket.assigns.current_user)
            )
            |> assign(:messages, [])

          {:ok, socket}
        end

        def handle_params(%{"conversation_id" => conversation_id}, _, socket) do
          conversation =
            #{inspect(chat)}.get_conversation!(conversation_id, actor: socket.assigns.current_user)

          cond do
            socket.assigns[:conversation] && socket.assigns[:conversation].id == conversation.id ->
              :ok

            socket.assigns[:conversation] ->
              #{inspect(endpoint)}.unsubscribe("chat:messages:\#{socket.assigns.conversation.id}")
              #{inspect(endpoint)}.subscribe("chat:messages:\#{conversation.id}")
            true ->
              #{inspect(endpoint)}.subscribe("chat:messages:\#{conversation.id}")
          end

          socket
          |> assign(:conversation, conversation)
          |> stream(:messages, #{inspect(chat)}.message_history!(conversation.id, stream?: true))
          |> assign_message_form()
          |> then(&{:noreply, &1})
        end

        def handle_params(_, _, socket) do
          if socket.assigns[:conversation] do
            #{inspect(endpoint)}.unsubscribe("chat:messages:\#{socket.assigns.conversation.id}")
          end

          socket
          |> assign(:conversation, nil)
          |> stream(:messages, [])
          |> assign_message_form()
          |> then(&{:noreply, &1})
        end

        def handle_event("validate_message", %{"form" => params}, socket) do
          {:noreply, assign(socket, :message_form, AshPhoenix.Form.validate(socket.assigns.message_form, params))}
        end

        def handle_event("send_message", %{"form" => params}, socket) do
          case AshPhoenix.Form.submit(socket.assigns.message_form, params: params) do
            {:ok, message} ->
              if socket.assigns.conversation do
                socket
                |> assign_message_form()
                |> stream_insert(:messages, message, at: 0)
                |> then(&{:noreply, &1})
              else
                {:noreply,
                 socket
                 |> push_navigate(to: ~p"/chat/\#{message.conversation_id}")}
              end

            {:error, form} ->
              {:noreply, assign(socket, :message_form, form)}
          end
        end

        def handle_info(
              %Phoenix.Socket.Broadcast{
                topic: "chat:messages:" <> conversation_id,
                payload: message
              },
              socket
            ) do
          if socket.assigns.conversation && socket.assigns.conversation.id == conversation_id do
            {:noreply, stream_insert(socket, :messages, message, at: 0)}
          else
            {:noreply, socket}
          end
        end

        def handle_info(
              %Phoenix.Socket.Broadcast{
                topic: "chat:conversations:" <> _,
                payload: conversation
              },
              socket
            ) do
          socket =
            if socket.assigns.conversation && socket.assigns.conversation.id == conversation.id do
              assign(socket, :conversation, conversation)
            else
              socket
            end

          {:noreply, stream_insert(socket, :conversations, conversation)}
        end

        defp assign_message_form(socket) do
          form =
            if socket.assigns.conversation do
              #{inspect(chat)}.form_to_create_message(
                actor: socket.assigns.current_user,
                private_arguments: %{conversation_id: socket.assigns.conversation.id}
              )
              |> to_form()
            else
              #{inspect(chat)}.form_to_create_message(actor: socket.assigns.current_user)
              |> to_form()
            end

          assign(
            socket,
            :message_form,
            form
          )
        end
      """
    end
  end
else
  defmodule Mix.Tasks.AshAi.Gen.Chat do
    @shortdoc "#{__MODULE__.Docs.short_doc()} | Install `igniter` to use"

    @moduledoc __MODULE__.Docs.long_doc()

    use Mix.Task

    def run(_argv) do
      Mix.shell().error("""
      The task 'ash_ai.gen.chat' requires igniter. Please install igniter and try again.

      For more information, see: https://hexdocs.pm/igniter/readme.html#installation
      """)

      exit({:shutdown, 1})
    end
  end
end
