require 'csv'
require 'json'
require 'logger'

$JSON_BAD_NILS = true
$JSON_BAD_CURRENCY = true

require 'bigdecimal'

$err_log = Logger.new(STDERR)
$err_log.level = Logger::WARN


def do_stockitem_csv2json_conversion(srcCsvFname, dstJsonFname, row_mapper)
    out_fp = open(dstJsonFname, "w")

    $err_log.debug("Reading #{srcCsvFname}; outputting to #{dstJsonFname}")

    items_written = 0

    out_fp.write("[\n")
    CSV.foreach(srcCsvFname, headers: true) do |csv_record|
        if items_written > 0
            out_fp.write(",\n")
        end

        json_row = row_mapper.call(csv_record)
	 	out_fp.write(JSON.pretty_generate(json_row))

        items_written += 1
    end
    out_fp.write("\n]\n")

ensure
    out_fp.close()

end

#
# Take a dictionary with keys like:
#
#   groupname_1_fieldname:          "a",
#   groupname_1_otherfieldname:     "b",
#   groupname_2_fieldname:          "c",
#   groupname_2_otherfieldname:     "d",
#
# and remap it to:
#
#   groupname: {
#       "1": {
#           "fieldname":      ...
#           "otherfieldname": ...
#       },
#       "2": {
#           "fieldname":      ...
#           "otherfieldname": ...
#       },
#   }
#
# Also supports renaming groupnames, if a custom mapper function is provided
#
def raise_keys_to_hashes(orig_dict, pattern, group_name_remapper = lambda { |x| x })
    new_dict = {}

    orig_dict.each { |k,v|
        m = pattern.match(k)
        if m
            group_name = group_name_remapper.call(m[1])
            group_idx = m[2]
            group_idx_field = m[3]

            $err_log.debug("raise_keys_to_hashes: m matched; it is #{m.inspect}")
            $err_log.debug("group_name is #{group_name}; group_idx is #{group_idx}; group_idx_field is #{group_idx_field}")

            if not new_dict.has_key?(group_name)
                new_dict[group_name] = {}
            end

            if not new_dict[group_name].has_key?(group_idx)
                new_dict[group_name][group_idx] = {}
            end

            new_dict[group_name][group_idx][group_idx_field] = v

        else
            $err_log.debug("raise_keys_to_hashes: key #{k} not matched; passing value #{v} through.")
            new_dict[k] = v

        end
    }

    return new_dict
end

def modifier_name_is_nil(mod_name, mod_fields)
    mod_fields.each { |k,v|
        match = k == "name"

        if $JSON_BAD_NILS
            match &&= v == "nil"
        else
            match &&= v == nil
        end

        if match
            return true
        end
    }

    return false
end


def apply_matched_lambdas_on_keys(key_to_lambda_map, orig_hash)
    new_hash = {}

    orig_hash.each { |k,v|
        catch :early_map_return do
            key_to_lambda_map.each{ |lmk,lmv|
                if lmk.match(k)
                    mapper = key_to_lambda_map[lmk]

                    new_hash[k] = mapper.call(v)
                    $err_log.debug("Mapped key '#{k}' (value '#{v}') to value '#{new_hash[k]}'")

                    throw :early_map_return
                end
            }

            $err_log.debug("Passing through key '#{k}' (value '#{v}')")
            new_hash[k] = v
        end
    }

    return new_hash
end

def csv_quantity_parser(quan_str)
    if quan_str == "nil"
        if $JSON_BAD_NILS == true
            return "nil"
        else
            return nil
        end
    else
        return quan_str.to_i
    end
end

def csv_price_parser(price_str)
    $err_log.debug("csv_price_parser(#{price_str}): called")
    if price_str == nil
        $err_log.debug("csv_price_parser(#{price_str}): returning nil")
        if $JSON_BAD_NILS == true
            return "nil"
        else
            return nil
        end
    end

    is_neg = false

    if price_str.start_with?("-")
        $err_log.debug("csv_price_parser(#{price_str}): is negative")
        is_neg = true
        price_str = price_str[1..-1]
    end

    if price_str.start_with?("$")
        $err_log.debug("csv_price_parser(#{price_str}): has dollar")
        price_str = price_str[1..-1]
    end

    if $JSON_BAD_CURRENCY == true
        val = price_str.to_f
    else
        val = BigDecimal.new(price_str)
    end

    if is_neg
        val = -val
    end

    $err_log.debug("csv_price_parser(#{price_str}): returning val #{val.inspect}")
    return val
end

def csv_string_parser(s)
    if s == nil
        if $JSON_BAD_NILS == true
            return "nil"
        else
            return nil
        end
    else
        return s
    end
end

def stockitem_mapper(row)
    stockitem_mappings = {
        /^item id$/                 =>   lambda { |x| x.to_i },
        /^modifier_[0-9]+_name$/    =>   lambda { |x| csv_string_parser(x) },
        /^price$/                   =>   lambda { |x| csv_price_parser(x) },
        /^modifier_[0-9]+_price$/   =>   lambda { |x| csv_price_parser(x) },
        /^cost$/                    =>   lambda { |x| csv_price_parser(x) },
        /^quantity_on_hand$/        =>   lambda { |x| csv_quantity_parser(x) }
    }

    modifier_to_modifiers = lambda { |k| k == "modifier" ? "modifiers" : k }
    key_to_hash_pattern = /^(modifier)_([0-9]+)_([a-zA-Z_]+)$/

    type_converted_fields = apply_matched_lambdas_on_keys(stockitem_mappings, row)
    $err_log.debug("type_converted_fields are currently #{type_converted_fields.inspect}")

    final_dict = raise_keys_to_hashes(type_converted_fields, key_to_hash_pattern, group_name_remapper=modifier_to_modifiers)

    $err_log.debug("final_dict is currently #{final_dict.inspect}")

    if final_dict.has_key?('modifiers')
        final_dict['modifiers'].delete_if { |k,v| modifier_name_is_nil(k,v) }
    end

    $err_log.debug("final_dict is currently #{final_dict.inspect}")

    $err_log.debug("final_dict.price is #{final_dict['price']}")
    $err_log.debug("final_dict.cost is #{final_dict['cost']}")

    return final_dict
end


