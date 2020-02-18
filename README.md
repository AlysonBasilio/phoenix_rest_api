# Microsservices model

## First Step: API REST

### Setting up our Phoenix Dockerfile
We will use the follow Dockerfile content as base for our APIs
```
FROM elixir:1.10.1-alpine

ARG USER_ID
ARG GROUP_ID

RUN addgroup -g $GROUP_ID user_group
RUN adduser -D -g '' -u $USER_ID -G user_group user
USER user

RUN mix local.hex --force && mix archive.install hex phx_new 1.4.13 --force
```

Build our image
```
docker build --build-arg USER_ID=$(id -u) --build-arg GROUP_ID=$(id -g) -t elixir-phoenix:alyson .
```

### Creating a new Phoenix API Project

With our image ready, we can now create our project
```
docker container run -it --rm -v "$(pwd)":/app -w /app --user $(id -u):$(id -g) --name elixir-order-api elixir-phoenix:alyson mix phx.new order_api --no-webpack --no-html
```
Output
```
We are almost there! The following steps are missing:

    $ cd order_api

Then configure your database in config/dev.exs and run:

    $ mix ecto.create

Start your Phoenix app with:

    $ mix phx.server

You can also run your app inside IEx (Interactive Elixir) as:

    $ iex -S mix phx.server
```

### Setting up our dockerized database instance
Let's setup our database
  - Edit config/dev.exs and config/test.exs by changing database hostname to "postgres"
```
config :order_api, OrderApi.Repo,
  username: "postgres",
  password: "postgres",
  database: "order_api_dev",
  hostname: "postgres",
  show_sensitive_data_on_connection_error: true,
  pool_size: 10
```
Now we will create a docker network and run our postgres container
```
docker network create poc_network
docker container run -d --rm -e POSTGRES_USER=postgres -e POSTGRES_PASSWORD=postgres -e PGDATA=/var/lib/postgresql/data/pgdata -v $(pwd)/pgdata:/var/lib/postgresql/data --name postgres --network poc_network --network-alias postgres postgres:12.1-alpine
```
Finally, we can create our api database
```
docker container run -it --rm -v $(pwd)/order_api:/app -w /app --user $(id -u):$(id -g) --name elixir-order-api --network poc_network elixir-phoenix:alyson mix ecto.create
```

### First Execution

Let's run our api!
```
docker container run -d --rm -v $(pwd)/order_api:/app -w /app --user $(id -u):$(id -g) --name elixir-order-api --network poc_network --network-alias order-api --publish 4000:4000 elixir-phoenix:alyson mix phx.server
```
Access [localhost:4000](localhost:4000)
Let's explore our recently created phoenix project:
  - mix.exs
  - lib/order_api/application.ex
  - lib/order_api_web/router.ex

```
  docker exec -it elixir-order-api sh
  mix help
  mix phx.routes
```

### Setting up resource routes

Now that we created our project, let's create our REST api routes by running the follow command inside our running container
```
mix phx.gen.json Orders Order orders user_id:integer offer_id:integer status:string
```
Output
```
Add the resource to your :api scope in lib/order_api_web/router.ex:
    resources "/orders", OrderController, except: [:new, :edit]
Remember to update your repository by running migrations:
    $ mix ecto.migrate
```
After restarting our container we can test all routes
```
docker restart elixir-order-api

curl -X POST -H "Content-Type: application/json" localhost:4000/api/v1/orders -d '{ "order": { "offer_id": 1, "user_id": 1, "status": "initiated" } }'

curl -X GET -H "Content-Type: application/json" localhost:4000/api/v1/orders

curl -X PATCH -H "Content-Type: application/json" localhost:4000/api/v1/orders/1 -d '{ "order": { "status": "paid" } }'

curl -X DELETE -H "Content-Type: application/json" localhost:4000/api/v1/orders/1
```

### Running tests
By using `mix phx.gen.json`, some tests were automatically implemented. Let's run them
```
docker container run -it --rm -v "$(pwd)/order_api":/app -w /app --user $(id -u):$(id -g) --name elixir-order-api-test --network poc_network elixir-phoenix:alyson mix test
```

## Second Step: Add Model State Machine and it methods (RPC)

### Adding new hex package
Edit the file `mix.exs` by adding `ecto_state_machine` to its dependencies:
```
defp deps do
  [
    {:phoenix, "~> 1.4.13"},
    {:phoenix_pubsub, "~> 1.1"},
    {:phoenix_ecto, "~> 4.0"},
    {:ecto_sql, "~> 3.1"},
    {:postgrex, ">= 0.0.0"},
    {:gettext, "~> 0.11"},
    {:jason, "~> 1.0"},
    {:plug_cowboy, "~> 2.0"},
    {:ecto_state_machine, "~> 0.3.0"}
  ]
end
```
Install the new depency and restart container
```
docker exec -it elixir-order-api sh
mix deps.get
docker restart elixir-order-api
```

### Editing Order model
Add the following code to the file `lib/order_api/orders/order.ex`
```
defmodule OrderApi.Orders.Order do
  use Ecto.Schema
  use EctoStateMachine,
    column: :status,
    states: [:registered, :interested, :compromised],
    events: [
      [
        name:     :demonstrated_interest,
        from:     [:registered],
        to:       :interested,
      ], [
        name:     :compromised_order,
        from:     [:registered, :interested],
        to:       :compromised
      ]
    ]
  import Ecto.Changeset

  schema "orders" do
    field :offer_id, :integer
    field :status, :string, default: "registered"
    field :user_id, :integer

    timestamps()
  end

  @doc false
  def changeset(order, attrs) do
    order
    |> cast(attrs, [:user_id, :offer_id, :status])
    |> validate_required([:user_id, :offer_id, :status])
  end
end
```

### Adding Routes to state transition
In the file `lib/order_web_api/router.ex` edit the `resources "orders"` line to
```
resources "/orders", OrderController, except: [:new, :edit] do
  put "/transitate/:event", OrderController, :transitate
end
```
Now, lets create our exposed method in the controller `lib/order_api_web/controllers/order_controller`
```
def transitate(conn, %{"order_id" => id, "event" => event}) do
  order = Orders.get_order!(id)
  new_order_changeset = apply(Order, String.to_atom(event), [order])

  if new_order_changeset.valid? do
    with {:ok, %Order{} = new_order} <- Orders.update_order(order, new_order_changeset.changes) do
      render(conn, "show.json", order: new_order)
    end
  else
    conn
    |> put_status(:unprocessable_entity)
    |> put_view(OrderApiWeb.ChangesetView)
    |> render("error.json", changeset: new_order_changeset)
  end
end
```
