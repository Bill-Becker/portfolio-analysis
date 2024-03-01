using REopt
using GhpGhx
using JuMP
using HiGHS
using JSON
using REoptPlots
using DataFrames
using CSV
using DotEnv
DotEnv.load!()
# Add a file called .env and add NREL_DEVELOPER_API_KEY="your_api_key_here" on the first line

# Start from base inputs file
input_data = JSON.parsefile("inputs.json")
# Define site specific parameters to assign to input_data Dict
# Site cities = San Francisco, Albany, Tampa, Chicago, Chicago
opt_tol = [0.01, 0.01, 0.01, 0.01, 0.01]
lat = [37.886, 27.994, 42.668, 41.834, 41.834]
long = [-120.130, -82.766, -73.852, -88.044, -88.044]
roof_ksqft = [15, 15, 25, 15, 10]
land_acres = [5, 10, 15, 15, 5]
avg_elec_load = [3500, 3500, 3500, 3500, 2000]  # kW
avg_ng_load = [8, 8, 8, 8, 6]  # MMBtu/hr
# Adding factor for lower electricity costs to account for not being able to avoid all demand charges
elec_cost_factor = 0.8
elec_cost_industrial = [0.1855, 0.0688, 0.0923, 0.0849, 0.0849] .* elec_cost_factor  # From https://www.eia.gov/state/data.php?sid=CA by state, industrial
elec_cost_commercial = [0.2314, 0.1798, 0.1184, 0.1117, 0.1117] .* elec_cost_factor  # From https://www.eia.gov/state/data.php?sid=CA by state, commercial
elec_cost_avg = [(elec_cost_industrial[i] + elec_cost_commercial[i]) / 2 for i in eachindex(elec_cost_industrial)]
ng_cost_industrial = [13.73, 11.30, 9.38, 9.17, 9.17] ./ 1.039  # https://www.eia.gov/dnav/ng/ng_pri_sum_dcu_SCA_a.htm by state, industrial
ng_cost_commercial = [16.13, 10.31, 14.18, 12.2, 12.2] ./ 1.039 # https://www.eia.gov/dnav/ng/ng_pri_sum_dcu_SCA_a.htm by state, commercial
ng_cost_avg = [(ng_cost_industrial[i] + ng_cost_commercial[i]) / 2 for i in eachindex(ng_cost_industrial)]
site_analysis = []

# Run REopt for each site after assigning input_data fields specific to the site
# If not evaluating all sites, for debugging, adjust sites_iter
sites_iter = eachindex(lat)
for i in sites_iter
    input_data_site = copy(input_data)
    # Site Specific
    input_data_site["Site"]["latitude"] = lat[i]
    input_data_site["Site"]["longitude"] = long[i]
    input_data_site["ElectricLoad"]["annual_kwh"] = avg_elec_load[i] * 8760.0
    input_data_site["DomesticHotWaterLoad"]["annual_mmbtu"] = avg_ng_load[i] * 8760.0
    input_data_site["Site"]["land_acres"] = land_acres[i]
    input_data_site["Site"]["roof_squarefeet"] = roof_ksqft[i] * 1000.0
    input_data_site["ElectricTariff"]["blended_annual_energy_rate"] = elec_cost_avg[i]
    export_credit_fraction = 0.75
    input_data_site["ElectricTariff"]["wholesale_rate"] = elec_cost_avg[i] * export_credit_fraction
    # But since this wholesale_rate could lead to technology over-sizing, constrain size to annual load
    # Guessing capacity factor for PV and Wind to avoid producing more than ~100% of site load
    input_data_site["PV"]["max_kw"] = avg_elec_load[i] / 0.15
    input_data_site["PV"]["installed_cost_per_kw"] = 1500.0
    wind_max_load = avg_elec_load[i] / 0.35
    wind_max_land = land_acres[i] / 0.03 # acres per kW * ac, which is only enforced in REopt IF > 1.5MW, so it's sizing to <=1.5MW
    input_data_site["Wind"]["max_kw"] = min(wind_max_load, wind_max_land)
    input_data_site["Wind"]["size_class"] = "medium"
    # Calc CHP heuristic that REopt would also calc, but assume 80% boiler effic, 34% elec effic, 44% thermal effic based on recip SC 3
    chp_heuristic_kw = avg_ng_load[i] * 0.8 * 1E6 / 3412 * 1 / 0.34 * 0.44
    input_data_site["CHP"]["max_kw"] = min(avg_elec_load[i], chp_heuristic_kw)  # Rely on max being 2x avg heating load size
    input_data_site["CHP"]["fuel_cost_per_mmbtu"] = ng_cost_avg[i]
    input_data_site["ExistingBoiler"]["fuel_cost_per_mmbtu"] = ng_cost_avg[i]
    s = Scenario(input_data_site)
    inputs = REoptInputs(s)
    println("CHP size class = ", s.chp.size_class)

    # Xpress solver
    # m1 = Model(optimizer_with_attributes(Xpress.Optimizer, "MIPRELSTOP" => opt_tol[i], "OUTPUTLOG" => 0))
    # m2 = Model(optimizer_with_attributes(Xpress.Optimizer, "MIPRELSTOP" => opt_tol[i], "OUTPUTLOG" => 0))

    # HiGHS solver
    m1 = Model(optimizer_with_attributes(HiGHS.Optimizer, 
            "time_limit" => 450.0,
            "mip_rel_gap" => opt_tol[i],
            "output_flag" => false, 
            "log_to_console" => false)
            )

    m2 = Model(optimizer_with_attributes(HiGHS.Optimizer, 
            "time_limit" => 450.0,
            "mip_rel_gap" => opt_tol[i],
            "output_flag" => false, 
            "log_to_console" => false)
            )            

    results = run_reopt([m1,m2], inputs)
    append!(site_analysis, [(input_data_site, results)])
end

# Print tech sizes
for i in sites_iter
    for tech in ["PV", "Wind", "CHP"]
        if haskey(site_analysis[i][2], tech)
            println("Site $i $tech size (kW) = ", site_analysis[i][2][tech]["size_kw"])
        end
    end
end

# Write results to dataframe

df = DataFrame(site = [i for i in sites_iter], 
               pv_size = [round(site_analysis[i][2]["PV"]["size_kw"], digits=0) for i in sites_iter],
               wind_size = [round(site_analysis[i][2]["Wind"]["size_kw"], digits=0) for i in sites_iter],
               chp_size = [round(site_analysis[i][2]["CHP"]["size_kw"], digits=0) for i in sites_iter],
               npv = [round(site_analysis[i][2]["Financial"]["npv"], sigdigits=3) for i in sites_iter],
               renewable_electricity_annual_kwh = [round(site_analysis[i][2]["Site"]["annual_renewable_electricity_kwh"], digits=3) for i in sites_iter],
               emissions_reduction_annual_ton = [round(site_analysis[i][2]["Site"]["lifecycle_emissions_reduction_CO2_fraction"] *
                                                    site_analysis[i][2]["Site"]["annual_emissions_tonnes_CO2_bau"], digits=0) for i in sites_iter]
               )

CSV.write("./portfolio.csv", df)

# results = run_reopt(m1, inputs)

# open("plot_results.json","w") do f
#     JSON.print(f, results)
# end

# plot_electric_dispatch(results)