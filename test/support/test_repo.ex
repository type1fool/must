defmodule Must.SQLiteEventStoreTestRepo do
  use Ecto.Repo,
    otp_app: :must,
    adapter: Ecto.Adapters.SQLite3
end

defmodule Must.SQLiteEventStoreTestBidRepo do
  use Ecto.Repo,
    otp_app: :must,
    adapter: Ecto.Adapters.SQLite3
end
