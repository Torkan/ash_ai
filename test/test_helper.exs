ExUnit.start()

AshAi.TestRepo.start_link()
Ecto.Adapters.SQL.Sandbox.mode(AshAi.TestRepo, :manual)
