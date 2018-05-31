class NECB2015

  # Applies the standard efficiency ratings and typical performance curves to this object.
  #
  # @return [Bool] true if successful, false if not
  def chiller_electric_eir_apply_efficiency_and_curves(chiller_electric_eir, clg_tower_objs)
    chillers = standards_data['chillers']

    # Define the criteria to find the chiller properties
    # in the hvac standards data set.
    search_criteria = chiller_electric_eir_find_search_criteria(chiller_electric_eir)
    cooling_type = search_criteria['cooling_type']
    condenser_type = search_criteria['condenser_type']
    compressor_type = search_criteria['compressor_type']

    # Get the chiller capacity
    capacity_w = chiller_electric_eir_find_capacity(chiller_electric_eir)

    # All chillers must be modulating down to 25% of their capacity
    chiller_electric_eir.setChillerFlowMode('LeavingSetpointModulated')
    chiller_electric_eir.setMinimumPartLoadRatio(0.25)
    chiller_electric_eir.setMinimumUnloadingRatio(0.25)
    if (capacity_w / 1000.0) < 2100.0
      if chiller_electric_eir.name.to_s.include? 'Primary Chiller'
        chiller_capacity = capacity_w
      elsif chiller_electric_eir.name.to_s.include? 'Secondary Chiller'
        chiller_capacity = 0.001
      end
    else
      chiller_capacity = capacity_w / 2.0
    end
    chiller_electric_eir.setReferenceCapacity(chiller_capacity)

    # Convert capacity to tons
    capacity_tons = OpenStudio.convert(chiller_capacity, 'W', 'ton').get

    # Get the chiller properties
    chlr_props = model_find_object(chillers, search_criteria, capacity_tons, Date.today)
    unless chlr_props
      OpenStudio.logFree(OpenStudio::Warn, 'openstudio.standards.ChillerElectricEIR', "For #{chiller_electric_eir.name}, cannot find chiller properties, cannot apply standard efficiencies or curves.")
      successfully_set_all_properties = false
      return successfully_set_all_properties
    end

    # Make the CAPFT curve
    cool_cap_ft = model_add_curve(chiller_electric_eir.model, chlr_props['capft'])
    if cool_cap_ft
      chiller_electric_eir.setCoolingCapacityFunctionOfTemperature(cool_cap_ft)
    else
      OpenStudio.logFree(OpenStudio::Warn, 'openstudio.standards.ChillerElectricEIR', "For #{chiller_electric_eir.name}, cannot find cool_cap_ft curve, will not be set.")
      successfully_set_all_properties = false
    end

    # Make the EIRFT curve
    cool_eir_ft = model_add_curve(chiller_electric_eir.model, chlr_props['eirft'])
    if cool_eir_ft
      chiller_electric_eir.setElectricInputToCoolingOutputRatioFunctionOfTemperature(cool_eir_ft)
    else
      OpenStudio.logFree(OpenStudio::Warn, 'openstudio.standards.ChillerElectricEIR', "For #{chiller_electric_eir.name}, cannot find cool_eir_ft curve, will not be set.")
      successfully_set_all_properties = false
    end

    # Make the EIRFPLR curve
    # which may be either a CurveBicubic or a CurveQuadratic based on chiller type
    cool_plf_fplr = model_add_curve(chiller_electric_eir.model, chlr_props['eirfplr'])
    if cool_plf_fplr
      chiller_electric_eir.setElectricInputToCoolingOutputRatioFunctionOfPLR(cool_plf_fplr)
    else
      OpenStudio.logFree(OpenStudio::Warn, 'openstudio.standards.ChillerElectricEIR', "For #{chiller_electric_eir.name}, cannot find cool_plf_fplr curve, will not be set.")
      successfully_set_all_properties = false
    end

    # Set the efficiency value
    kw_per_ton = nil
    cop = nil
    if chlr_props['minimum_full_load_efficiency']
      kw_per_ton = chlr_props['minimum_full_load_efficiency']
      cop = kw_per_ton_to_cop(kw_per_ton)
      chiller_electric_eir.setReferenceCOP(cop)
    else
      OpenStudio.logFree(OpenStudio::Warn, 'openstudio.standards.ChillerElectricEIR', "For #{chiller_electric_eir.name}, cannot find minimum full load efficiency, will not be set.")
      successfully_set_all_properties = false
    end

    # Set cooling tower properties now that the new COP of the chiller is set
    if chiller_electric_eir.name.to_s.include? 'Primary Chiller'
      # Single speed tower model assumes 25% extra for compressor power
      tower_cap = capacity_w * (1.0 + 1.0 / chiller_electric_eir.referenceCOP)
      if (tower_cap / 1000.0) < 1750
        clg_tower_objs[0].setNumberofCells(1)
      else
        clg_tower_objs[0].setNumberofCells((tower_cap / (1000 * 1750) + 0.5).round)
      end
      clg_tower_objs[0].setFanPoweratDesignAirFlowRate(0.013 * tower_cap)
    end

    # Append the name with size and kw/ton
    chiller_electric_eir.setName("#{chiller_electric_eir.name} #{capacity_tons.round}tons #{kw_per_ton.round(1)}kW/ton")
    OpenStudio.logFree(OpenStudio::Info, 'openstudio.model.ChillerElectricEIR', "For #{template}: #{chiller_electric_eir.name}: #{cooling_type} #{condenser_type} #{compressor_type} Capacity = #{capacity_tons.round}tons; COP = #{cop.round(1)} (#{kw_per_ton.round(1)}kW/ton)")

    return successfully_set_all_properties
  end

  # Searches through any hydronic loops and applies the maxmimum total pump power by modifying the pump design power consumption.
  # This is as per NECB2015 5.2.6.3.(1)
  def apply_maximum_loop_pump_power(model)
    testdata = @standards_data['max_total_loop_pump_power']['table']
    plant_loops = model.getPlantLoops
    return model if plant_loops.nil?
    plant_loops.each do |plantloop|
      next if plant_loop_swh_loop?(plantloop) == true
      pumps = []
      max_powertoload = 0
      plantloop.supplyComponents.each do |supplycomp|
        supplycomp_type = supplycomp.iddObjectType.valueName.to_s
        case supplycomp.iddObjectType.valueName.to_s
          when 'OS_Boiler_HotWater'
            max_powertoload = model_find_object(@standards_data['max_total_loop_pump_power'], 'hydronic_system_type' => 'Heating')['total_normalized_pump_power_wperkw']
          when 'OS_Chiller_Electric_EIR'
            max_powertoload = model_find_object(@standards_data['max_total_loop_pump_power'], 'hydronic_system_type' => 'Cooling')['total_normalized_pump_power_wperkw']
          when 'OS_CoolingTower_SingleSpeed'
            max_powertoload = model_find_object(@standards_data['max_total_loop_pump_power'], 'hydronic_system_type' => 'Heat_rejection')['total_normalized_pump_power_wperkw']
          when 'OS_Pump_VariableSpeed'
            pumps << supplycomp
          when 'OS_Pump_ConstantSpeed'
            pumps << supplycomp
        end
      end
      next if max_powertoload == 0 || pumps.length == 0
      comp_list = []
      plantloop.demandComponents.each do |demandcomp|
        case demandcomp.iddObjectType.valueName.to_s
          when 'OS_Coil_Heating_Water_Baseboard'
            comp_list << demandcomp
          when 'OS_Coil_Cooling_Water'
            comp_list << demandcomp
          when 'OS_Coil_Heating_Water'
            comp_list << demandcomp
          when 'OS_Coil_CoolingTower_SingleSpeed'
            comp_list << demandcomp
        end
        puts "What next?"
      end
      unless comp_list.empty?
        comp_list.each do |comp|
#          rel = comp.straightComponent.get
#          puts rel
        end
      end
    end
    return model
  end

end
