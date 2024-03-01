using REopt

sim_load_dict = Dict([("latitude", 37.7),
                    ("longitude", -118.5),
                    ("load_type", "electric"),
                    ("doe_reference_name", "Hospital"),
                    ("annual_kwh", 10.0e6)])

data = simulated_load(sim_load_dict)

