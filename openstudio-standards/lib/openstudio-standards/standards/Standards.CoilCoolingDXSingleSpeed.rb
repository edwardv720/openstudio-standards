
# Reopen the OpenStudio class to add methods to apply standards to this object
class OpenStudio::Model::CoilCoolingDXSingleSpeed
  # Finds the search criteria
  #
  # @param template [String] valid choices: 'DOE Ref Pre-1980', 'DOE Ref 1980-2004', '90.1-2004', '90.1-2007', '90.1-2010', '90.1-2013'
  # @return [hash] has for search criteria to be used for find object
  def find_search_criteria(template)
    # Define the criteria to find the chiller properties
    # in the hvac standards data set.
    search_criteria = {}
    search_criteria['template'] = template
    cooling_type = condenserType
    search_criteria['cooling_type'] = cooling_type

    # Determine the heating type if unitary or zone hvac
    heat_pump = false
    heating_type = nil
    if airLoopHVAC.empty?
      if containingHVACComponent.is_initialized
        containing_comp = containingHVACComponent.get
        if containing_comp.to_AirLoopHVACUnitaryHeatPumpAirToAir.is_initialized
          heat_pump = true
          heating_type = 'Electric Resistance or None'
        end # TODO: Add other unitary systems
      elsif containingZoneHVACComponent.is_initialized
        containing_comp = containingZoneHVACComponent.get
        if containing_comp.to_ZoneHVACPackagedTerminalAirConditioner.is_initialized
          htg_coil = containing_comp.to_ZoneHVACPackagedTerminalAirConditioner.get.heatingCoil
          if htg_coil.to_CoilHeatingElectric.is_initialized
            heating_type = 'Electric Resistance or None'
          elsif htg_coil.to_CoilHeatingWater.is_initialized || htg_coil.to_CoilHeatingGas.is_initialized
            heating_type = 'All Other'
          end
        end # TODO: Add other zone hvac systems
      end
    end

    # Determine the heating type if on an airloop
    if airLoopHVAC.is_initialized
      air_loop = airLoopHVAC.get
      heating_type = if !air_loop.supplyComponents('OS:Coil:Heating:Electric'.to_IddObjectType).empty?
                       'Electric Resistance or None'
                     elsif !air_loop.supplyComponents('OS:Coil:Heating:Gas'.to_IddObjectType).empty?
                       'All Other'
                     elsif !air_loop.supplyComponents('OS:Coil:Heating:Water'.to_IddObjectType).empty?
                       'All Other'
                     elsif !air_loop.supplyComponents('OS:Coil:Heating:DX:SingleSpeed'.to_IddObjectType).empty?
                       'All Other'
                     elsif !air_loop.supplyComponents('OS:Coil:Heating:Gas:MultiStage'.to_IddObjectType).empty?
                       'All Other'
                     elsif !air_loop.supplyComponents('OS:Coil:Heating:Desuperheater'.to_IddObjectType).empty?
                       'All Other'
                     elsif !air_loop.supplyComponents('OS:Coil:Heating:WaterToAirHeatPump:EquationFit'.to_IddObjectType).empty?
                       'All Other'
                     else
                       'Electric Resistance or None'
                     end
    end

    # Add the heating type to the search criteria
    unless heating_type.nil?
      search_criteria['heating_type'] = heating_type
    end

    # TODO: Standards - add split system vs single package to model
    # For now, assume single package
    subcategory = 'Single Package'
    search_criteria['subcategory'] = subcategory

    return search_criteria
  end

  # Finds capacity in Btu/hr
  #
  # @return [Double] capacity in Btu/hr to be used for find object
  def find_capacity
    # Get the coil capacity
    capacity_w = nil
    if ratedTotalCoolingCapacity.is_initialized
      capacity_w = ratedTotalCoolingCapacity.get
    elsif autosizedRatedTotalCoolingCapacity.is_initialized
      capacity_w = autosizedRatedTotalCoolingCapacity.get
    else
      OpenStudio.logFree(OpenStudio::Warn, 'openstudio.standards.CoilCoolingDXSingleSpeed', "For #{name} capacity is not available, cannot apply efficiency standard.")
      return false
    end

    # Convert capacity to Btu/hr
    capacity_btu_per_hr = OpenStudio.convert(capacity_w, 'W', 'Btu/hr').get

    return capacity_btu_per_hr
  end

  # Finds lookup object in standards and return efficiency
  #
  # @param template [String] valid choices: 'DOE Ref Pre-1980', 'DOE Ref 1980-2004', '90.1-2004', '90.1-2007', '90.1-2010', '90.1-2013'
  # @param standards [Hash] the OpenStudio_Standards spreadsheet in hash format
  # @return [Double] full load efficiency (COP)
  def standard_minimum_cop(template, standards)
    # find ac properties
    search_criteria = find_search_criteria(template)
    cooling_type = search_criteria['cooling_type']
    heating_type = search_criteria['heating_type']
    subcategory = search_criteria['subcategory']
    capacity_btu_per_hr = find_capacity
    capacity_kbtu_per_hr = OpenStudio.convert(capacity_btu_per_hr, 'Btu/hr', 'kBtu/hr').get

    ac_props = model.find_object(standards['unitary_acs'], search_criteria, capacity_btu_per_hr, Date.today)

    # Get the minimum efficiency standards
    cop = nil

    # Check to make sure properties were found
    if ac_props.nil?
      OpenStudio.logFree(OpenStudio::Warn, 'openstudio.standards.CoilCoolingDXSingleSpeed', "For #{name}, cannot find efficiency info, cannot apply efficiency standard.")
      return cop # value of nil
    end

    # If specified as SEER
    unless ac_props['minimum_seasonal_energy_efficiency_ratio'].nil?
      min_seer = ac_props['minimum_seasonal_energy_efficiency_ratio']
      cop = seer_to_cop_cooling_no_fan(min_seer)
      OpenStudio.logFree(OpenStudio::Info, 'openstudio.standards.CoilCoolingDXSingleSpeed', "For #{template}: #{name}: #{cooling_type} #{heating_type} #{subcategory} Capacity = #{capacity_kbtu_per_hr.round}kBtu/hr; SEER = #{min_seer}")
    end

    # If specified as EER
    unless ac_props['minimum_energy_efficiency_ratio'].nil?
      min_eer = ac_props['minimum_energy_efficiency_ratio']
      cop = eer_to_cop(min_eer, OpenStudio.convert(capacity_kbtu_per_hr, 'kBtu/hr', 'W').get)
      OpenStudio.logFree(OpenStudio::Info, 'openstudio.standards.CoilCoolingDXSingleSpeed', "For #{template}: #{name}: #{cooling_type} #{heating_type} #{subcategory} Capacity = #{capacity_kbtu_per_hr.round}kBtu/hr; EER = #{min_eer}")
    end

    # if specified as SEER (heat pump)
    unless ac_props['minimum_seasonal_efficiency'].nil?
      min_seer = ac_props['minimum_seasonal_efficiency']
      cop = seer_to_cop_cooling_no_fan(min_seer)
      OpenStudio.logFree(OpenStudio::Info, 'openstudio.standards.CoilCoolingDXSingleSpeed', "For #{template}: #{name}: #{cooling_type} #{heating_type} #{subcategory} Capacity = #{capacity_kbtu_per_hr.round}kBtu/hr; SEER = #{min_seer}")
    end

    # If specified as EER (heat pump)
    unless ac_props['minimum_full_load_efficiency'].nil?
      min_eer = ac_props['minimum_full_load_efficiency']
      cop = eer_to_cop(min_eer, OpenStudio.convert(capacity_kbtu_per_hr, 'kBtu/hr', 'W').get)
      OpenStudio.logFree(OpenStudio::Info, 'openstudio.standards.CoilCoolingDXSingleSpeed', "For #{template}: #{name}: #{cooling_type} #{heating_type} #{subcategory} Capacity = #{capacity_kbtu_per_hr.round}kBtu/hr; EER = #{min_eer}")
    end

    return cop
  end

  # Applies the standard efficiency ratings and typical performance curves to this object.
  #
  # @param template [String] valid choices: 'DOE Ref Pre-1980', 'DOE Ref 1980-2004', '90.1-2004', '90.1-2007', '90.1-2010', '90.1-2013'
  # @param standards [Hash] the OpenStudio_Standards spreadsheet in hash format
  # @return [Bool] true if successful, false if not
  def apply_efficiency_and_curves(template, sql_db_vars_map)
    successfully_set_all_properties = true

    unitary_acs = $os_standards['unitary_acs']
    heat_pumps = $os_standards['heat_pumps']

    # Define the criteria to find the chiller properties
    # in the hvac standards data set.
    search_criteria = {}
    search_criteria['template'] = template
    cooling_type = condenserType
    search_criteria['cooling_type'] = cooling_type

    # TODO: Standards - add split system vs single package to model
    # For now, assume single package as default
    subcategory = 'Single Package'

    # Determine the heating type if unitary or zone hvac
    heat_pump = false
    heating_type = nil
    if airLoopHVAC.empty?
      if containingHVACComponent.is_initialized
        containing_comp = containingHVACComponent.get
        if containing_comp.to_AirLoopHVACUnitaryHeatPumpAirToAir.is_initialized
          heat_pump = true
          heating_type = 'Electric Resistance or None'
        end # TODO: Add other unitary systems
      elsif containingZoneHVACComponent.is_initialized
        containing_comp = containingZoneHVACComponent.get
        # PTAC
        if containing_comp.to_ZoneHVACPackagedTerminalAirConditioner.is_initialized
          subcategory = 'PTAC'
          htg_coil = containing_comp.to_ZoneHVACPackagedTerminalAirConditioner.get.heatingCoil
          if htg_coil.to_CoilHeatingElectric.is_initialized
            heating_type = 'Electric Resistance or None'
          elsif htg_coil.to_CoilHeatingWater.is_initialized || htg_coil.to_CoilHeatingGas.is_initialized
            heating_type = 'All Other'
          end
        # PTHP
        elsif containing_comp.to_ZoneHVACPackagedTerminalHeatPump.is_initialized
          subcategory = 'PTHP'
          heating_type = 'Electric Resistance or None'
          heat_pump = true
        end # TODO: Add other zone hvac systems

      end
    end

    # Determine the heating type if on an airloop
    if airLoopHVAC.is_initialized
      air_loop = airLoopHVAC.get
      heating_type = if !air_loop.supplyComponents('OS:Coil:Heating:Electric'.to_IddObjectType).empty?
                       'Electric Resistance or None'
                     elsif !air_loop.supplyComponents('OS:Coil:Heating:Gas'.to_IddObjectType).empty?
                       'All Other'
                     elsif !air_loop.supplyComponents('OS:Coil:Heating:Water'.to_IddObjectType).empty?
                       'All Other'
                     elsif !air_loop.supplyComponents('OS:Coil:Heating:DX:SingleSpeed'.to_IddObjectType).empty?
                       'All Other'
                     elsif !air_loop.supplyComponents('OS:Coil:Heating:Gas:MultiStage'.to_IddObjectType).empty?
                       'All Other'
                     elsif !air_loop.supplyComponents('OS:Coil:Heating:Desuperheater'.to_IddObjectType).empty?
                       'All Other'
                     elsif !air_loop.supplyComponents('OS:Coil:Heating:WaterToAirHeatPump:EquationFit'.to_IddObjectType).empty?
                       'All Other'
                     else
                       'Electric Resistance or None'
                     end
    end

    # Add the heating type to the search criteria
    unless heating_type.nil?
      search_criteria['heating_type'] = heating_type
    end

    search_criteria['subcategory'] = subcategory

    # Get the coil capacity
    capacity_w = nil
    if ratedTotalCoolingCapacity.is_initialized
      capacity_w = ratedTotalCoolingCapacity.get
    elsif autosizedRatedTotalCoolingCapacity.is_initialized
      capacity_w = autosizedRatedTotalCoolingCapacity.get
    else
      OpenStudio.logFree(OpenStudio::Warn, 'openstudio.standards.CoilCoolingDXSingleSpeed', "For #{name} capacity is not available, cannot apply efficiency standard.")
      successfully_set_all_properties = false
      return successfully_set_all_properties
    end

    # If it's a PTAC or PTHP System, we need to divide the capacity by the potential zone multiplier
    # because the COP is dependent on capacity, and the capacity should be the capacity of a single zone, not all the zones
    if ['PTAC', 'PTHP'].include?(subcategory)
      mult = 1
      comp = containingZoneHVACComponent
      if comp.is_initialized
        if comp.get.thermalZone.is_initialized
          mult = comp.get.thermalZone.get.multiplier
          if mult > 1
            total_cap = capacity_w
            capacity_w /= mult
            OpenStudio.logFree(OpenStudio::Info, 'openstudio.standards.CoilCoolingDXSingleSpeed', "For #{name}, total capacity of #{OpenStudio.convert(total_cap, 'W', 'kBtu/hr').get.round(2)}kBTU/hr was divided by the zone multiplier of #{mult} to give #{capacity_kbtu_per_hr = OpenStudio.convert(capacity_w, 'W', 'kBtu/hr').get.round(2)}kBTU/hr.")
          end
        end
      end
    end

    # Convert capacity to Btu/hr
    capacity_btu_per_hr = OpenStudio.convert(capacity_w, 'W', 'Btu/hr').get
    capacity_kbtu_per_hr = OpenStudio.convert(capacity_w, 'W', 'kBtu/hr').get

    # Lookup efficiencies depending on whether it is a unitary AC or a heat pump
    ac_props = nil
    ac_props = if heat_pump == true
                 model.find_object(heat_pumps, search_criteria, capacity_btu_per_hr, Date.today)
               else
                 model.find_object(unitary_acs, search_criteria, capacity_btu_per_hr, Date.today)
               end

    # Check to make sure properties were found
    if ac_props.nil?
      OpenStudio.logFree(OpenStudio::Warn, 'openstudio.standards.CoilCoolingDXSingleSpeed', "For #{name}, cannot find efficiency info, cannot apply efficiency standard.")
      successfully_set_all_properties = false
      return successfully_set_all_properties
    end

    # Make the COOL-CAP-FT curve
    cool_cap_ft = model.add_curve(ac_props['cool_cap_ft'])
    if cool_cap_ft
      setTotalCoolingCapacityFunctionOfTemperatureCurve(cool_cap_ft)
    else
      OpenStudio.logFree(OpenStudio::Warn, 'openstudio.standards.CoilCoolingDXSingleSpeed', "For #{name}, cannot find cool_cap_ft curve, will not be set.")
      successfully_set_all_properties = false
    end

    # Make the COOL-CAP-FFLOW curve
    cool_cap_fflow = model.add_curve(ac_props['cool_cap_fflow'])
    if cool_cap_fflow
      setTotalCoolingCapacityFunctionOfFlowFractionCurve(cool_cap_fflow)
    else
      OpenStudio.logFree(OpenStudio::Warn, 'openstudio.standards.CoilCoolingDXSingleSpeed', "For #{name}, cannot find cool_cap_fflow curve, will not be set.")
      successfully_set_all_properties = false
    end

    # Make the COOL-EIR-FT curve
    cool_eir_ft = model.add_curve(ac_props['cool_eir_ft'])
    if cool_eir_ft
      setEnergyInputRatioFunctionOfTemperatureCurve(cool_eir_ft)
    else
      OpenStudio.logFree(OpenStudio::Warn, 'openstudio.standards.CoilCoolingDXSingleSpeed', "For #{name}, cannot find cool_eir_ft curve, will not be set.")
      successfully_set_all_properties = false
    end

    # Make the COOL-EIR-FFLOW curve
    cool_eir_fflow = model.add_curve(ac_props['cool_eir_fflow'])
    if cool_eir_fflow
      setEnergyInputRatioFunctionOfFlowFractionCurve(cool_eir_fflow)
    else
      OpenStudio.logFree(OpenStudio::Warn, 'openstudio.standards.CoilCoolingDXSingleSpeed', "For #{name}, cannot find cool_eir_fflow curve, will not be set.")
      successfully_set_all_properties = false
    end

    # Make the COOL-PLF-FPLR curve
    cool_plf_fplr = model.add_curve(ac_props['cool_plf_fplr'])
    if cool_plf_fplr
      setPartLoadFractionCorrelationCurve(cool_plf_fplr)
    else
      OpenStudio.logFree(OpenStudio::Warn, 'openstudio.standards.CoilCoolingDXSingleSpeed', "For #{name}, cannot find cool_plf_fplr curve, will not be set.")
      successfully_set_all_properties = false
    end

    # Get the minimum efficiency standards
    cop = nil

    # If PTHP, use equations
    if subcategory == 'PTHP'
      pthp_eer_coeff_1 = ac_props['pthp_eer_coefficient_1']
      pthp_eer_coeff_2 = ac_props['pthp_eer_coefficient_2']
      # TABLE 6.8.1D
      # EER = pthp_eer_coeff_1 - (pthp_eer_coeff_2 * Cap / 1000)
      # Note c: Cap means the rated cooling capacity of the product in Btu/h.
      # If the unit's capacity is less than 7000 Btu/h, use 7000 Btu/h in the calculation.
      # If the unit's capacity is greater than 15,000 Btu/h, use 15,000 Btu/h in the calculation.
      eer_calc_cap_btu_per_hr = capacity_btu_per_hr
      eer_calc_cap_btu_per_hr = 7000 if capacity_btu_per_hr < 7000
      eer_calc_cap_btu_per_hr = 15_000 if capacity_btu_per_hr > 15_000
      pthp_eer = pthp_eer_coeff_1 - (pthp_eer_coeff_2 * eer_calc_cap_btu_per_hr / 1000.0)
      cop = eer_to_cop(pthp_eer, OpenStudio.convert(capacity_btu_per_hr, 'Btu/hr', 'W').get)
      new_comp_name = "#{name} #{capacity_kbtu_per_hr.round}kBtu/hr #{pthp_eer.round(1)}EER"
      OpenStudio.logFree(OpenStudio::Info, 'openstudio.standards.CoilCoolingDXSingleSpeed', "For #{name}: #{cooling_type} #{heating_type} #{subcategory} Capacity = #{capacity_kbtu_per_hr.round}kBtu/hr; EER = #{pthp_eer.round(2)}")
    end

    # If PTAC, use equations
    if subcategory == 'PTAC'
      ptac_eer_coeff_1 = ac_props['ptac_eer_coefficient_1']
      ptac_eer_coeff_2 = ac_props['ptac_eer_coefficient_2']
      # TABLE 6.8.1D
      # EER = ptac_eer_coeff_1 - (ptac_eer_coeff_2 * Cap / 1000)
      # Note c: Cap means the rated cooling capacity of the product in Btu/h.
      # If the unit's capacity is less than 7000 Btu/h, use 7000 Btu/h in the calculation.
      # If the unit's capacity is greater than 15,000 Btu/h, use 15,000 Btu/h in the calculation.
      eer_calc_cap_btu_per_hr = capacity_btu_per_hr      
      eer_calc_cap_btu_per_hr = 7000 if capacity_btu_per_hr < 7000
      eer_calc_cap_btu_per_hr = 15_000 if capacity_btu_per_hr > 15_000
      ptac_eer = ptac_eer_coeff_1 - (ptac_eer_coeff_2 * eer_calc_cap_btu_per_hr / 1000.0)
      cop = eer_to_cop(ptac_eer, OpenStudio.convert(capacity_btu_per_hr, 'Btu/hr', 'W').get)
      new_comp_name = "#{name} #{capacity_kbtu_per_hr.round}kBtu/hr #{ptac_eer.round(1)}EER"
      OpenStudio.logFree(OpenStudio::Info, 'openstudio.standards.CoilCoolingDXSingleSpeed', "For #{name}: #{cooling_type} #{heating_type} #{subcategory} Capacity = #{capacity_kbtu_per_hr.round}kBtu/hr; EER = #{ptac_eer}")
    end

    # If specified as SEER
    unless ac_props['minimum_seasonal_energy_efficiency_ratio'].nil?
      min_seer = ac_props['minimum_seasonal_energy_efficiency_ratio']
      cop = seer_to_cop_cooling_no_fan(min_seer)
      new_comp_name = "#{name} #{capacity_kbtu_per_hr.round}kBtu/hr #{min_seer}SEER"
      #      self.setName("#{self.name} #{capacity_kbtu_per_hr.round}kBtu/hr #{min_seer}SEER")
      OpenStudio.logFree(OpenStudio::Info, 'openstudio.standards.CoilCoolingDXSingleSpeed', "For #{template}: #{name}: #{cooling_type} #{heating_type} #{subcategory} Capacity = #{capacity_kbtu_per_hr.round}kBtu/hr; SEER = #{min_seer}")
    end

    # If specified as EER
    unless ac_props['minimum_energy_efficiency_ratio'].nil?
      min_eer = ac_props['minimum_energy_efficiency_ratio']
      cop = eer_to_cop(min_eer, OpenStudio.convert(capacity_kbtu_per_hr, 'kBtu/hr', 'W').get)
      new_comp_name = "#{name} #{capacity_kbtu_per_hr.round}kBtu/hr #{min_eer}EER"
      OpenStudio.logFree(OpenStudio::Info, 'openstudio.standards.CoilCoolingDXSingleSpeed', "For #{template}: #{name}: #{cooling_type} #{heating_type} #{subcategory} Capacity = #{capacity_kbtu_per_hr.round}kBtu/hr; EER = #{min_eer}")
    end

    # if specified as SEER (heat pump)
    unless ac_props['minimum_seasonal_efficiency'].nil?
      min_seer = ac_props['minimum_seasonal_efficiency']
      cop = seer_to_cop_cooling_no_fan(min_seer)
      new_comp_name = "#{name} #{capacity_kbtu_per_hr.round}kBtu/hr #{min_seer}SEER"
      #      self.setName("#{self.name} #{capacity_kbtu_per_hr.round}kBtu/hr #{min_seer}SEER")
      OpenStudio.logFree(OpenStudio::Info, 'openstudio.standards.CoilCoolingDXSingleSpeed', "For #{template}: #{name}: #{cooling_type} #{heating_type} #{subcategory} Capacity = #{capacity_kbtu_per_hr.round}kBtu/hr; SEER = #{min_seer}")
    end

    # If specified as EER (heat pump)
    unless ac_props['minimum_full_load_efficiency'].nil?
      min_eer = ac_props['minimum_full_load_efficiency']
      cop = eer_to_cop(min_eer, OpenStudio.convert(capacity_kbtu_per_hr, 'kBtu/hr', 'W').get)
      new_comp_name = "#{name} #{capacity_kbtu_per_hr.round}kBtu/hr #{min_eer}EER"
      OpenStudio.logFree(OpenStudio::Info, 'openstudio.standards.CoilCoolingDXSingleSpeed', "For #{template}: #{name}: #{cooling_type} #{heating_type} #{subcategory} Capacity = #{capacity_kbtu_per_hr.round}kBtu/hr; EER = #{min_eer}")
    end

    sql_db_vars_map[new_comp_name] = name.to_s
    setName(new_comp_name)

    # Set the efficiency values
    unless cop.nil?
      setRatedCOP(OpenStudio::OptionalDouble.new(cop))
    end

    return sql_db_vars_map
  end
end
