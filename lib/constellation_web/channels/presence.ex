defmodule ConstellationWeb.Presence do
  use Phoenix.Presence,
    otp_app: :constellation,
    pubsub_server: Constellation.PubSub
end
