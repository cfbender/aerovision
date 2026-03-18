defmodule AeroVision.MixProject do
  use Mix.Project

  @app :aerovision
  @version "0.1.0"
  @all_targets [:rpi0_2]

  def project do
    [
      app: @app,
      version: @version,
      elixir: "~> 1.17",
      archives: [nerves_bootstrap: "~> 1.13"],
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      releases: [{@app, release()}],
      aliases: aliases(),
      compilers: [:phoenix_live_view] ++ Mix.compilers(),
      listeners:
        if(System.get_env("MIX_TARGET") in [nil, "", "host"],
          do: [Phoenix.CodeReloader],
          else: []
        ),
      elixirc_paths: elixirc_paths(Mix.env()),
      test_coverage: [
        summary: [threshold: 60],
        ignore_modules: [
          # LiveViews require full integration testing infrastructure
          AeroVisionWeb.DashboardLive,
          AeroVisionWeb.SettingsLive,
          AeroVisionWeb.SetupLive,
          # Framework boilerplate — minimal custom code
          AeroVisionWeb.Endpoint,
          AeroVisionWeb.Router,
          AeroVisionWeb.Layouts,
          AeroVisionWeb.CoreComponents,
          # Nerves target-only display driver (wraps Port/binary)
          AeroVision.Display.Driver
        ]
      ]
    ]
  end

  # On host (dev + test): include lib/stubs so target-only modules like
  # VintageNet, Circuits.GPIO, and Nerves.Runtime have stub definitions
  # that satisfy the compiler without producing "undefined module" warnings.
  # On a real Nerves target (MIX_TARGET=rpi0_2): the real deps are available,
  # so stubs must NOT be compiled or they'll conflict.
  defp elixirc_paths(:test), do: host_paths() ++ ["test/support"]
  defp elixirc_paths(_), do: host_paths()

  defp host_paths do
    if System.get_env("MIX_TARGET") in [nil, "", "host"] do
      ["lib", "host_stubs"]
    else
      ["lib"]
    end
  end

  def cli do
    [
      preferred_targets: [run: :host, test: :host],
      preferred_envs: [precommit: :test]
    ]
  end

  def application do
    [
      mod: {AeroVision.Application, []},
      extra_applications: [:logger, :runtime_tools, :crypto]
    ]
  end

  defp deps do
    [
      # Nerves core
      {:nerves, "~> 1.10", runtime: false},
      {:shoehorn, "~> 0.9", targets: @all_targets},
      {:ring_logger, "~> 0.11", targets: @all_targets},
      {:toolshed, "~> 0.4", targets: @all_targets},
      {:nerves_runtime, "~> 0.13", targets: @all_targets},
      {:nerves_pack, "~> 0.7", targets: @all_targets},
      {:nerves_ssh, "~> 1.3", targets: @all_targets},

      # Nerves system — only built for the rpi0_2 target
      {:nerves_system_rpi0_2, "~> 1.33", runtime: false, targets: :rpi0_2},

      # Phoenix web stack
      {:phoenix, "~> 1.8.5"},
      {:phoenix_html, "~> 4.1"},
      {:phoenix_live_reload, "~> 1.2", only: :dev},
      {:phoenix_live_view, "~> 1.1.0"},
      {:lazy_html, ">= 0.1.0", only: :test},
      {:bandit, "~> 1.5"},

      # Data / storage
      {:jason, "~> 1.4"},
      {:cubdb, "~> 2.0"},

      # HTTP client
      {:req, "~> 0.5"},
      {:castore, "~> 1.0"},

      # Hardware
      {:circuits_gpio, "~> 2.0", targets: @all_targets},
      {:muontrap, "~> 1.0"},

      # Assets
      {:esbuild, "~> 0.10", runtime: false},
      {:tailwind, "~> 0.3", runtime: false},
      {:heroicons,
       github: "tailwindlabs/heroicons", tag: "v2.1.1", sparse: "optimized", app: false, compile: false, depth: 1},

      # Utilities
      {:mimic, "~> 2.0", only: :test},
      {:floki, "~> 0.38.0"},
      {:dns_cluster, "~> 0.1"},
      {:telemetry_metrics, "~> 1.0"},
      {:telemetry_poller, "~> 1.0"},
      {:styler, "~> 1.11", only: [:dev, :test], runtime: false},
      {:zoneinfo, "~> 0.1"}
    ]
  end

  defp release do
    [
      overwrite: true,
      # Nerves-specific release settings
      cookie: "#{@app}_cookie",
      include_erts: &Nerves.Release.erts/0,
      steps: [&Nerves.Release.init/1, :assemble],
      strip_beams: Mix.env() == :prod
    ]
  end

  defp aliases do
    [
      loadconfig: [&bootstrap/1],
      setup: ["deps.get", "assets.setup", &copy_zoneinfo/1],
      precommit: ["format", "compile --warnings-as-errors", "test"],
      build: ["assets.deploy", "firmware"],
      "build.driver": ["cmd --cd go_src make build-arm"],
      "build.driver.host": ["cmd --cd go_src make build-host"],
      deploy: ["assets.deploy", "build.driver", "firmware", "upload aerovision.local"],
      "assets.setup": ["tailwind.install --if-missing", "esbuild.install --if-missing"],
      "assets.build": ["compile", "tailwind aerovision", "esbuild aerovision"],
      "assets.deploy": [
        "tailwind aerovision --minify",
        "esbuild aerovision --minify",
        "phx.digest"
      ]
    ]
  end

  # Copies the host system's IANA timezone database into the Nerves rootfs overlay
  # so the device has tz data available at /usr/share/zoneinfo/ at runtime.
  # The source (/usr/share/zoneinfo) is present on macOS and all major Linux distros.
  defp copy_zoneinfo(_args) do
    src = "/usr/share/zoneinfo"
    dst = Path.join([File.cwd!(), "rootfs_overlay", "usr", "share", "zoneinfo"])

    if File.exists?(src) do
      File.rm_rf!(dst)
      File.mkdir_p!(Path.dirname(dst))
      File.cp_r!(src, dst, dereference_symlinks: true)
      Mix.shell().info("[:zoneinfo] Copied #{src} → #{dst}")
    else
      Mix.shell().error(
        "[:zoneinfo] #{src} not found — timezone data not copied. " <>
          "Install tzdata (e.g. `brew install tzdata` or `apt install tzdata`)."
      )
    end
  end

  # Nerves requires loading the config before deps are available, so we call the
  # bootstrap archive function which sets up the Nerves target environment.
  defp bootstrap(args) do
    Application.start(:nerves_bootstrap)
    Mix.Task.run("loadconfig", args)
  end
end
