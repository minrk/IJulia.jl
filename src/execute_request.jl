using DataDisplay

# History: global In/Out and other history variables exported to Main
const In = Dict{Integer,UTF8String}()
const Out = Dict{Integer,Any}()
_ = __ = __ = ans = nothing
export In, Out, _, __, ___, ans

# return a String=>String dictionary of mimetype=>data for passing to
# IPython display_data and pyout messages.
function display_dict(x)
    data = [ "text/plain" => string_text(x) ]
    if can_write_svg(x)
        data["image/svg+xml"] = string_svg(x)
    end
    if can_write_png(x)
        data["image/png"] = string_png(x)
    elseif can_write_jpeg(x) # sending both jpeg and png seems redundant
        data["image/jpeg"] = string_jpeg(x)
    end
    if can_write_html(x)
        data["text/html"] = string_html(x)
    end
    if can_write_latex(x)
        data["application/x-latex"] = string_latex(x)
    end
    if can_write_javascript(x)
        data["application/javascript"] = string_javascript(x)
    end
    return data
end

# global variable so that display can be done in the correct Msg context
execute_msg = nothing

# note: 0x535c5df2 is a random integer to make name collisions in
# backtrace analysis less likely.
function execute_request_0x535c5df2(socket, msg)
    if verbose
        println("EXECUTING ", msg.content["code"])
    end

    global execute_msg = msg
    global _n, In, Out, _, __, ___, ans
    silent = msg.content["silent"] || ismatch(r";\s*$", msg.content["code"])

    # present in spec but missing from notebook's messages:
    store_history = get(msg.content, "store_history", !silent)

    if !silent
        _n += 1
        if store_history
            In[_n] = msg.content["code"]
        end
        send_ipython(publish, 
                     msg_pub(msg, "pyin",
                             ["execution_count" => _n,
                              "code" => msg.content["code"]]))
    elseif verbose
        println("SILENT")
    end

    send_status("busy")

    try 
        ans = result = include_string(msg.content["code"], "In[$_n]")
        if silent
            result = nothing
        elseif result != nothing
            ___ = __ # 3rd result from last
            __ = _ # 2nd result from last
            _ = result
            if store_history
                Out[_n] = result == Out ? nothing : result # Julia #3066
                eval(Main, :($(symbol(string("_",_n))) = $result))
            end
        end

        user_variables = Dict()
        user_expressions = Dict()
        for v in msg.content["user_variables"]
            user_variables[v] = eval(Main,parse(v))
        end
        for (v,ex) in msg.content["user_expressions"]
            user_expressions[v] = eval(Main,parse(ex))
        end

        if result != nothing
            send_ipython(publish, 
                         msg_pub(msg, "pyout",
                                 ["execution_count" => _n,
                                 "metadata" => Dict(), # qtconsole needs this
                                 "data" => display_dict(result) ]))
        end

        send_ipython(requests,
                     msg_reply(msg, "execute_reply",
                               ["status" => "ok", "execution_count" => _n,
                               "payload" => [],
                               "user_variables" => user_variables,
                                "user_expressions" => user_expressions]))
    catch e
        tb = split(sprint(Base.show_backtrace, :execute_request_0x535c5df2, 
                          catch_backtrace(), 1:typemax(Int)), "\n", false)
        if !isempty(tb) && ismatch(r"^\s*in\s+include_string\s+", tb[end])
            pop!(tb) # don't include include_string in backtrace
        end
        ename = string(typeof(e))
        evalue = sprint(Base.error_show, e)
        unshift!(tb, evalue) # fperez says this needs to be in traceback too
        send_ipython(publish,
                     msg_pub(msg, "pyerr",
                               ["execution_count" => _n,
                               "ename" => ename, "evalue" => evalue,
                               "traceback" => tb]))
        send_ipython(requests,
                     msg_reply(msg, "execute_reply",
                               ["status" => "error", "execution_count" => _n,
                               "ename" => ename, "evalue" => evalue,
                               "traceback" => tb]))
    end

    execute_msg = nothing
    send_status("idle")
end
