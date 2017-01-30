# Based on src/http/ngx_http_parse.c from NGINX copyright Igor Sysoev
#
# Additional changes are licensed under the same terms as NGINX and
# copyright Joyent, Inc. and other Node contributors. All rights reserved.
#
# Permission is hereby granted, free of charge, to any person obtaining a copy
# of this software and associated documentation files (the "Software"), to
# deal in the Software without restriction, including without limitation the
# rights to use, copy, modify, merge, publish, distribute, sublicense, and/or
# sell copies of the Software, and to permit persons to whom the Software is
# furnished to do so, subject to the following conditions:
#
# The above copyright notice and this permission notice shall be included in
# all copies or substantial portions of the Software.
#
# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
# IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
# FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
# AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
# LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING
# FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS
# IN THE SOFTWARE.
#

#TODO
  # re-write parsing.jl tests to use HTTP.parse(!)
  # update types.jl, client.jl code, remove current parser.jl file

type Parser
    state::UInt8
    header_state::UInt8
    index::UInt8
    flags::UInt8
    nread::UInt32
    content_length::UInt64
    fieldbuffer::Vector{UInt8}
    valuebuffer::Vector{UInt8}
end

Parser() = Parser(s_start_req_or_res, 0x00, 0, 0, 0, 0, UInt8[], UInt8[])

const HTTP_MAX_HEADER_SIZE = 80 * 1024

macro nread(n)
    return esc(quote
        parser.nread += UInt32($n)
        @errorif(parser.nread > HTTP_MAX_HEADER_SIZE, HPE_HEADER_OVERFLOW)
    end)
end

onmessagebegin(r) = @debug(DEBUG, "onmessagebegin")
# should we just make a copy of the byte vector for URI here?
function onurl(r, bytes, i, j)
    @debug(DEBUG, "onurl")
    @debug(DEBUG, i - j + 1)
    @debug(DEBUG, "'$(String(bytes[i:j]))'")
    @debug(DEBUG, r.method)
    uri = http_parser_parse_url(bytes, i, j - i + 1, r.method == CONNECT)
    @debug(DEBUG, uri)
    setfield!(r, :uri, uri)
    nothing
end
onstatus(r) = @debug(DEBUG, "onstatus")
function onheaderfield(p::Parser, bytes, i, j)
    @debug(DEBUG, "onheaderfield")
    append!(p.fieldbuffer, view(bytes, i:j))
end
function onheadervalue(p::Parser, bytes, i, j)
    @debug(DEBUG, "onheadervalue")
    append!(p.valuebuffer, view(bytes, i:j))
end
function onheadervalue(p, r, bytes, i, j, issetcookie, host)
    @debug(DEBUG, "onheadervalue2")
    append!(p.valuebuffer, view(bytes, i:j))
    val = unsafe_string(pointer(p.valuebuffer), length(p.valuebuffer))
    issetcookie && push!(r.cookies, Cookies.readsetcookie(host, val))
    r.headers[unsafe_string(pointer(p.fieldbuffer), length(p.fieldbuffer))] = val
    empty!(p.fieldbuffer)
    empty!(p.valuebuffer)
    return
end
onheaderscomplete(r) = @debug(DEBUG, "onheaderscomplete")
function onbody(r, bytes, i, j)
    @debug(DEBUG, "onbody")
    @debug(DEBUG, String(r.body))
    @debug(DEBUG, String(bytes[i:j]))
    len = j - i + 1
    nb = write(r.body, view(bytes, i:j))
    if nb < len # didn't write all available bytes
        if current_task() == MAINTASK
            # main request function hasn't returned yet, so not safe to wait
            r.body.max += len - nb
            write(r.body, view(bytes, (i + nb):j))
        else
            while nb < len
                nb += write(body, view(bytes, (i + nb):j))
            end
        end
    end
    @debug(DEBUG, String(r.body))
    return
end
onmessagecomplete(r::Request) = @debug(DEBUG, "onmessagecomplete")
onmessagecomplete(r::Response) = (@debug(DEBUG, "onmessagecomplete"); close(r.body))

const DEFAULT_PARSER = Parser()

function parse{T <: Union{Request, Response}}(::Type{T}, str)
    r = T()
    DEFAULT_PARSER.state = s_start_req_or_res
    DEFAULT_PARSER.header_state = 0x00
    err, headerscomplete, messagecomplete = parse!(r, DEFAULT_PARSER, Vector{UInt8}(str))
    err != HPE_OK && throw(ParsingError("error parsing $T: $(ParsingErrorCodeMap[err])"))
    # messagecomplete || throw(ParsingError("unable to parse full $T from provided string"))
    return r
end

const start_state = s_start_req_or_res

function parse!{T <: Union{Request, Response}}(r::T, parser, bytes, len=length(bytes);
        lenient::Bool=true, host::String="", method::HTTP.Method=GET)::Tuple{ParsingErrorCode, Bool, Bool}
    strict = !lenient
    p_state = parser.state
    status_mark = url_mark = header_field_mark = header_field_end_mark = header_value_mark = body_mark = 0
    errno = HPE_OK
    if len == 0
        if p_state == s_body_identity_eof
            @debug(DEBUG, ParsingStateCode(p_state))
            parser.state = p_state
            onmessagecomplete(r)
            return HPE_OK, true, true
        elseif p_state in (s_dead, s_start_req_or_res, s_start_res, s_start_req)
            return HPE_OK, false, false
        else
            return HPE_INVALID_EOF_STATE, false, false
        end
    end

    if p_state == s_header_field
        @debug(DEBUG, ParsingStateCode(p_state))
        header_field_mark = header_field_end_mark = 1
    end
    if p_state == s_header_value
        @debug(DEBUG, ParsingStateCode(p_state))
        header_value_mark = 1
    end
    if p_state in (s_req_path, s_req_schema, s_req_schema_slash, s_req_schema_slash_slash,
                   s_req_server_start, s_req_server, s_req_server_with_at,
                   s_req_query_string_start, s_req_query_string, s_req_fragment)
        url_mark = 1
    elseif p_state == s_res_status
        status_mark = 1
    end
    p = 1
    while p <= len
        ch = Char(bytes[p])
        @debug(DEBUG, ch)
        if p_state <= s_headers_done
            @nread(1)
        end

        @label reexecute

        if p_state == s_dead
            @debug(DEBUG, ParsingStateCode(p_state))
            #= this state is used after a 'Connection: close' message
             # the parser will error out if it reads another message
            =#
            (ch == CR || ch == LF) && @goto breakout
            @err HPE_CLOSED_CONNECTION

        elseif p_state == s_start_req_or_res
            @debug(DEBUG, ParsingStateCode(p_state))

            (ch == CR || ch == LF) && @goto breakout
            parser.flags = 0
            parser.content_length = ULLONG_MAX

            if ch == 'H'
                p_state = s_res_or_resp_H
                parser.state = p_state
                onmessagebegin(r)
            else
                p_state = s_start_req
                @goto reexecute
            end

        elseif p_state == s_res_or_resp_H
            @debug(DEBUG, ParsingStateCode(p_state))
            if ch == 'T'
                p_state = s_res_HT
            else
                @errorif(ch != 'E', HPE_INVALID_CONSTANT)
                r.method = HEAD
                parser.index = 3
                p_state = s_req_method
            end

        elseif p_state == s_start_res
            @debug(DEBUG, ParsingStateCode(p_state))
            parser.flags = 0
            parser.content_length = ULLONG_MAX
            if ch == 'H'
                p_state = s_res_H
            elseif ch == CR || ch == LF
            else
                @err HPE_INVALID_CONSTANT
            end
            parser.state = p_state
            onmessagebegin(r)

        elseif p_state == s_res_H
            @debug(DEBUG, ParsingStateCode(p_state))
            @strictcheck(ch != 'T')
            p_state = s_res_HT

        elseif p_state == s_res_HT
            @debug(DEBUG, ParsingStateCode(p_state))
            @strictcheck(ch != 'T')
            p_state = s_res_HTT

        elseif p_state == s_res_HTT
            @debug(DEBUG, ParsingStateCode(p_state))
            @strictcheck(ch != 'P')
            p_state = s_res_HTTP

        elseif p_state == s_res_HTTP
            @debug(DEBUG, ParsingStateCode(p_state))
            @strictcheck(ch != '/')
            p_state = s_res_first_http_major

        elseif p_state == s_res_first_http_major
            @debug(DEBUG, ParsingStateCode(p_state))
            @errorif(!isnum(ch), HPE_INVALID_VERSION)
            r.major = Int16(ch - '0')
            p_state = s_res_http_major

        #= major HTTP version or dot =#
        elseif p_state == s_res_http_major
            @debug(DEBUG, ParsingStateCode(p_state))
            if ch == '.'
                p_state = s_res_first_http_minor
                @goto breakout
            end
            @errorif(!isnum(ch), HPE_INVALID_VERSION)
            r.major *= Int16(10)
            r.major += Int16(ch - '0')
            @errorif(r.major > 999, HPE_INVALID_VERSION)

        #= first digit of minor HTTP version =#
        elseif p_state == s_res_first_http_minor
            @debug(DEBUG, ParsingStateCode(p_state))
            @errorif(!isnum(ch), HPE_INVALID_VERSION)
            r.minor = Int16(ch - '0')
            p_state = s_res_http_minor

        #= minor HTTP version or end of request line =#
        elseif p_state == s_res_http_minor
            @debug(DEBUG, ParsingStateCode(p_state))
            if ch == ' '
                p_state = s_res_first_status_code
                @goto breakout
            end
            @errorif(!isnum(ch), HPE_INVALID_VERSION)
            r.minor *= Int16(10)
            r.minor += Int16(ch - '0')
            @errorif(r.minor > 999, HPE_INVALID_VERSION)

        elseif p_state == s_res_first_status_code
            @debug(DEBUG, ParsingStateCode(p_state))
            if !isnum(ch)
                ch == ' ' && @goto breakout
                @err(HPE_INVALID_STATUS)
            end
            r.status = Int32(ch - '0')
            p_state = s_res_status_code

        elseif p_state == s_res_status_code
            @debug(DEBUG, ParsingStateCode(p_state))
            if !isnum(ch)
                if ch == ' '
                    p_state = s_res_status_start
                elseif ch == CR
                    p_state = s_res_line_almost_done
                elseif ch == LF
                    p_state = s_header_field_start
                else
                    @err(HPE_INVALID_STATUS)
                end
            else
                r.status *= Int32(10)
                r.status += Int32(ch - '0')
                @errorif(r.status > 999, HPE_INVALID_STATUS)
            end

        elseif p_state == s_res_status_start
            @debug(DEBUG, ParsingStateCode(p_state))
            if ch == CR
                p_state = s_res_line_almost_done
            elseif ch == LF
                p_state = s_header_field_start
            else
                status_mark = p
                p_state = s_res_status
                parser.index = 1
            end

        elseif p_state == s_res_status
            @debug(DEBUG, ParsingStateCode(p_state))
            if ch == CR
                p_state = s_res_line_almost_done
                parser.state = p_state
                onstatus(r)
            elseif ch == LF
                p_state = s_header_field_start
                parser.state = p_state
                onstatus(r)
            end

        elseif p_state == s_res_line_almost_done
            @debug(DEBUG, ParsingStateCode(p_state))
            @strictcheck(ch != LF)
            p_state = s_header_field_start

        elseif p_state == s_start_req
            @debug(DEBUG, ParsingStateCode(p_state))
            (ch == CR || ch == LF) && @goto breakout
            parser.flags = 0
            parser.content_length = ULLONG_MAX

            @errorif(!isalpha(ch), HPE_INVALID_METHOD)

            r.method = HTTP.Method(0)
            parser.index = 2

            if ch == 'A'
                r.method = ACL
            elseif ch == 'B'
                r.method = BIND
            elseif ch == 'C'
                r.method = CONNECT
            elseif ch == 'D'
                r.method = DELETE
            elseif ch == 'G'
                r.method = GET
            elseif ch == 'H'
                r.method = HEAD
            elseif ch == 'L'
                r.method = LOCK
            elseif ch == 'M'
                r.method = MKCOL
            elseif ch == 'N'
                r.method = NOTIFY
            elseif ch == 'O'
                r.method = OPTIONS
            elseif ch == 'P'
                r.method = POST
            elseif ch == 'R'
                r.method = REPORT
            elseif ch == 'S'
                r.method = SUBSCRIBE
            elseif ch == 'T'
                r.method = TRACE
            elseif ch == 'U'
                r.method = UNLOCK
            else
                @err(HPE_INVALID_METHOD)
            end
            p_state = s_req_method
            parser.state = p_state
            onmessagebegin(r)

        elseif p_state == s_req_method
            @debug(DEBUG, ParsingStateCode(p_state))
            @errorif(ch == '\0', HPE_INVALID_METHOD)

            matcher = string(r.method)
            @debug(DEBUG, matcher)
            @debug(DEBUG, parser.index)
            if ch == ' ' && parser.index == length(matcher)+1
                p_state = s_req_spaces_before_url
            elseif ch == matcher[parser.index]
                #= nada =#
            elseif isalpha(ch)
                c = @shifted(r.method, parser.index - 1, ch)
                if c == @shifted(POST, 1, 'U')
                    r.method = PUT
                elseif c == @shifted(POST, 1, 'A')
                    r.method =  PATCH
                elseif c == @shifted(CONNECT, 1, 'H')
                    r.method =  CHECKOUT
                elseif c == @shifted(CONNECT, 2, 'P')
                    r.method =  COPY
                elseif c == @shifted(MKCOL, 1, 'O')
                    r.method =  MOVE
                elseif c == @shifted(MKCOL, 1, 'E')
                    r.method =  MERGE
                elseif c == @shifted(MKCOL, 2, 'A')
                    r.method =  MKACTIVITY
                elseif c == @shifted(MKCOL, 3, 'A')
                    r.method =  MKCALENDAR
                elseif c == @shifted(SUBSCRIBE, 1, 'E')
                    r.method =  SEARCH
                elseif c == @shifted(REPORT, 2, 'B')
                    r.method =  REBIND
                elseif c == @shifted(POST, 1, 'R')
                    r.method =  PROPFIND
                elseif c == @shifted(PROPFIND, 4, 'P')
                    r.method =  PROPPATCH
                elseif c == @shifted(PUT, 2, 'R')
                    r.method =  PURGE
                elseif c == @shifted(LOCK, 1, 'I')
                    r.method =  LINK
                elseif c == @shifted(UNLOCK, 2, 'S')
                    r.method =  UNSUBSCRIBE
                elseif c == @shifted(UNLOCK, 2, 'B')
                    r.method =  UNBIND
                elseif c == @shifted(UNLOCK, 3, 'I')
                    r.method =  UNLINK
                else
                    @err(HPE_INVALID_METHOD)
                end
            elseif ch == '-' && parser.index == 2 && r.method == MKCOL
                r.method = MSEARCH
            else
                @err(HPE_INVALID_METHOD)
            end
            parser.index += 1
            @debug(DEBUG, parser.index)

        elseif p_state == s_req_spaces_before_url
            @debug(DEBUG, ParsingStateCode(p_state))
            ch == ' ' && @goto breakout
            url_mark = p
            if r.method == CONNECT
                p_state = s_req_server_start
            end
            p_state = parseurlchar(p_state, ch, strict)
            @errorif(p_state == s_dead, HPE_INVALID_URL)

        elseif p_state in (s_req_schema, s_req_schema_slash, s_req_schema_slash_slash, s_req_server_start)
            @errorif(ch in (' ', CR, LF), HPE_INVALID_URL)
            p_state = parseurlchar(p_state, ch, strict)
            @errorif(p_state == s_dead, HPE_INVALID_URL)

        elseif p_state in (s_req_server, s_req_server_with_at, s_req_path, s_req_query_string_start,
                           s_req_query_string, s_req_fragment_start, s_req_fragment)
            if ch == ' '
                p_state = s_req_http_start
                parser.state = p_state
                onurl(r, bytes, url_mark, p-1)
                url_mark = 0
            elseif ch in (CR, LF)
                r.major = Int16(0)
                r.minor = Int16(9)
                p_state = ch == CR ? s_req_line_almost_done : s_header_field_start
                parser.state = p_state
                onurl(r, bytes, url_mark, p-1)
                url_mark = 0
            else
                p_state = parseurlchar(p_state, ch, strict)
                @errorif(p_state == s_dead, HPE_INVALID_URL)
            end

        elseif p_state == s_req_http_start
            @debug(DEBUG, ParsingStateCode(p_state))
            if ch == 'H'
                p_state = s_req_http_H
            elseif ch == ' '
            else
                @err(HPE_INVALID_CONSTANT)
            end

        elseif p_state == s_req_http_H
            @debug(DEBUG, ParsingStateCode(p_state))
            @strictcheck(ch != 'T')
            p_state = s_req_http_HT

        elseif p_state == s_req_http_HT
            @debug(DEBUG, ParsingStateCode(p_state))
            @strictcheck(ch != 'T')
            p_state = s_req_http_HTT

        elseif p_state == s_req_http_HTT
            @debug(DEBUG, ParsingStateCode(p_state))
            @strictcheck(ch != 'P')
            p_state = s_req_http_HTTP

        elseif p_state == s_req_http_HTTP
            @debug(DEBUG, ParsingStateCode(p_state))
            @strictcheck(ch != '/')
            p_state = s_req_first_http_major

        #= first digit of major HTTP version =#
        elseif p_state == s_req_first_http_major
            @debug(DEBUG, ParsingStateCode(p_state))
            @errorif(ch < '1' || ch > '9', HPE_INVALID_VERSION)
            r.major = Int16(ch - '0')
            p_state = s_req_http_major

        #= major HTTP version or dot =#
        elseif p_state == s_req_http_major
            @debug(DEBUG, ParsingStateCode(p_state))
            if ch == '.'
                p_state = s_req_first_http_minor
            elseif !isnum(ch)
                @err(HPE_INVALID_VERSION)
            else
                r.major *= Int16(10)
                r.major += Int16(ch - '0')
                @errorif(r.major > 999, HPE_INVALID_VERSION)
            end

        #= first digit of minor HTTP version =#
        elseif p_state == s_req_first_http_minor
            @debug(DEBUG, ParsingStateCode(p_state))
            @errorif(!isnum(ch), HPE_INVALID_VERSION)
            r.minor = Int16(ch - '0')
            p_state = s_req_http_minor

        #= minor HTTP version or end of request line =#
        elseif p_state == s_req_http_minor
            @debug(DEBUG, ParsingStateCode(p_state))
            if ch == CR
                p_state = s_req_line_almost_done
            elseif ch == LF
                p_state = s_header_field_start
            else
                #= XXX allow spaces after digit? =#
                @errorif(!isnum(ch), HPE_INVALID_VERSION)
                r.minor *= Int16(10)
                r.minor += Int16(ch - '0')
                @errorif(r.minor > 999, HPE_INVALID_VERSION)
            end

        #= end of request line =#
        elseif p_state == s_req_line_almost_done
            @debug(DEBUG, ParsingStateCode(p_state))
            @errorif(ch != LF, HPE_LF_EXPECTED)
            p_state = s_header_field_start

        elseif p_state == s_header_field_start
            @debug(DEBUG, ParsingStateCode(p_state))
            if ch == CR
                p_state = s_headers_almost_done
            elseif ch == LF
                #= they might be just sending \n instead of \r\n so this would be
                 * the second \n to denote the end of headers=#
                p_state = s_headers_almost_done
                @goto reexecute
            else
                c = (!strict && ch == ' ') ? ' ' : tokens[Int(ch)+1]
                @errorif(c == Char(0), HPE_INVALID_HEADER_TOKEN)
                header_field_mark = header_field_end_mark = p
                parser.index = 1
                issetcookie = false
                p_state = s_header_field

                if c == 'c'
                    parser.header_state = h_C
                elseif c == 'p'
                    parser.header_state = h_matching_proxy_connection
                elseif c == 't'
                    parser.header_state = h_matching_transfer_encoding
                elseif c == 'u'
                    parser.header_state = h_matching_upgrade
                elseif c == 's'
                    parser.header_state = h_matching_setcookie
                else
                    parser.header_state = h_general
                end
            end

        elseif p_state == s_header_field
            println("parsing header_field")
            @debug(DEBUG, ParsingStateCode(p_state))
            start = p
            while p <= len
                ch = Char(bytes[p])
                @debug(DEBUG, ch)
                c = (!strict && ch == ' ') ? ' ' : tokens[Int(ch)+1]
                c == Char(0) && break
                h = parser.header_state
                if h == h_general
                    @debug(DEBUG, parser.header_state)

                elseif h == h_C
                    @debug(DEBUG, parser.header_state)
                    parser.index += 1
                    parser.header_state = c == 'o' ? h_CO : h_general
                elseif h == h_CO
                    @debug(DEBUG, parser.header_state)
                    parser.index += 1
                    parser.header_state = c == 'n' ? h_CON : h_general
                elseif h == h_CON
                    @debug(DEBUG, parser.header_state)
                    parser.index += 1
                    if c == 'n'
                        parser.header_state = h_matching_connection
                    elseif c == 't'
                        parser.header_state = h_matching_content_length
                    else
                        parser.header_state = h_general
                    end
                #= connection =#
                elseif h == h_matching_connection
                    @debug(DEBUG, parser.header_state)
                    parser.index += 1
                    if parser.index > length(CONNECTION) || c != CONNECTION[parser.index]
                        parser.header_state = h_general
                    elseif parser.index == length(CONNECTION)
                        parser.header_state = h_connection
                    end
                #= proxy-connection =#
                elseif h == h_matching_proxy_connection
                    @debug(DEBUG, parser.header_state)
                    parser.index += 1
                    if parser.index > length(PROXY_CONNECTION) || c != PROXY_CONNECTION[parser.index]
                        parser.header_state = h_general
                    elseif parser.index == length(PROXY_CONNECTION)
                        parser.header_state = h_connection
                    end
                #= content-length =#
                elseif h == h_matching_content_length
                    @debug(DEBUG, parser.header_state)
                    parser.index += 1
                    if parser.index > length(CONTENT_LENGTH) || c != CONTENT_LENGTH[parser.index]
                        parser.header_state = h_general
                    elseif parser.index == length(CONTENT_LENGTH)
                        parser.header_state = h_content_length
                    end
                #= transfer-encoding =#
                elseif h == h_matching_transfer_encoding
                    @debug(DEBUG, parser.header_state)
                    parser.index += 1
                    if parser.index > length(TRANSFER_ENCODING) || c != TRANSFER_ENCODING[parser.index]
                        parser.header_state = h_general
                    elseif parser.index == length(TRANSFER_ENCODING)
                        parser.header_state = h_transfer_encoding
                    end
                #= upgrade =#
                elseif h == h_matching_upgrade
                    @debug(DEBUG, parser.header_state)
                    parser.index += 1
                    if parser.index > length(UPGRADE) || c != UPGRADE[parser.index]
                        parser.header_state = h_general
                    elseif parser.index == length(UPGRADE)
                        parser.header_state = h_upgrade
                    end
                #= set-cookie =#
                elseif h == h_matching_setcookie
                    @debug(DEBUG, parser.header_state)
                    parser.index += 1
                    if parser.index > length(SETCOOKIE) || c != SETCOOKIE[parser.index]
                        parser.header_state = h_general
                    elseif parser.index == length(SETCOOKIE)
                        parser.header_state = h_general
                        issetcookie = true
                    end
                elseif h in (h_connection, h_content_length, h_transfer_encoding, h_upgrade)
                    if ch != ' '
                        parser.header_state = h_general
                    end
                else
                    error("Unknown header_state")
                end
                p += 1
            end

            @nread(p - start)

            if p == len
                p -= 1
                @goto breakout
            end
            if ch == ':'
                p_state = s_header_value_discard_ws
                parser.state = p_state
                header_field_end_mark = p
                onheaderfield(parser, bytes, header_field_mark, p - 1)
                header_field_mark = 0
            else
                @err(HPE_INVALID_HEADER_TOKEN)
            end

        elseif p_state == s_header_value_discard_ws
            @debug(DEBUG, ParsingStateCode(p_state))
            (ch == ' ' || ch == '\t') && @goto breakout
            if ch == CR
                p_state = s_header_value_discard_ws_almost_done
                @goto breakout
            end
            if ch == LF
                p_state = s_header_value_discard_lws
                @goto breakout
            end
            @goto s_header_value_start_label
        #= FALLTHROUGH =#
        elseif p_state == s_header_value_start
            @debug(DEBUG, ParsingStateCode(p_state))
            @label s_header_value_start_label
            header_value_mark = p
            p_state = s_header_value
            parser.index = 1
            c = lower(ch)

            if parser.header_state == h_upgrade
                parser.flags |= F_UPGRADE
                parser.header_state = h_general
            elseif parser.header_state == h_transfer_encoding
                #= looking for 'Transfer-Encoding: chunked' =#
                parser.header_state =  c == 'c' ? h_matching_transfer_encoding_chunked : h_general

            elseif parser.header_state == h_content_length
                @errorif(!isnum(ch), HPE_INVALID_CONTENT_LENGTH)
                @errorif((parser.flags & F_CONTENTLENGTH > 0) != 0, HPE_UNEXPECTED_CONTENT_LENGTH)
                parser.flags |= F_CONTENTLENGTH
                parser.content_length = UInt64(ch - '0')

            elseif parser.header_state == h_connection
                #= looking for 'Connection: keep-alive' =#
                if c == 'k'
                    parser.header_state = h_matching_connection_keep_alive
                #= looking for 'Connection: close' =#
                elseif c == 'c'
                    parser.header_state = h_matching_connection_close
                elseif c == 'u'
                    parser.header_state = h_matching_connection_upgrade
                else
                    parser.header_state = h_matching_connection_token
                end
            #= Multi-value `Connection` header =#
            elseif parser.header_state == h_matching_connection_token_start
            else
              parser.header_state = h_general
            end

        elseif p_state == s_header_value
            @debug(DEBUG, ParsingStateCode(p_state))
            start = p
            h = parser.header_state
            while p <= len
                ch = Char(bytes[p])
                @debug(DEBUG, ch)
                if ch == CR
                    p_state = s_header_almost_done
                    parser.header_state = h
                    parser.state = p_state
                    onheadervalue(parser, r, bytes, header_value_mark, p - 1, issetcookie, host)
                    header_value_mark = 0
                    break
                elseif ch == LF
                    p_state = s_header_almost_done
                    @nread(p - start)
                    parser.header_state = h
                    parser.state = p_state
                    onheadervalue(parser, r, bytes, header_value_mark, p - 2, issetcookie, host)
                    header_value_mark = 0
                    @goto reexecute
                elseif !lenient && !isheaderchar(ch)
                    @err(HPE_INVALID_HEADER_TOKEN)
                end

                c = lower(ch)

                if h == h_general
                    @debug(DEBUG, parser.header_state)
                    limit = len - p + 1
                    limit = min(limit, HTTP_MAX_HEADER_SIZE)
                    ptr = pointer(bytes, p)
                    p_cr = ccall(:memchr, Ptr{UInt8}, (Ptr{Void}, Cint, Csize_t), ptr, CR, limit)
                    p_lf = ccall(:memchr, Ptr{UInt8}, (Ptr{Void}, Cint, Csize_t), ptr, LF, limit)
                    if p_cr != C_NULL
                        if p_lf != C_NULL && p_cr >= p_lf
                            p += p_lf - ptr + 1
                        else
                            p += p_cr - ptr + 1
                        end
                    elseif p_lf != C_NULL
                        p += p_lf - ptr + 1
                    else
                        p = len
                    end
                    p -= 1

                elseif h == h_connection || h == h_transfer_encoding
                    error("Shouldn't get here.")
                elseif h == h_content_length
                    t = UInt64(0)
                    if ch == ' '
                    else
                        if !isnum(ch)
                            parser.header_state = h
                            @err(HPE_INVALID_CONTENT_LENGTH)
                        end
                        t = parser.content_length
                        t *= UInt64(10)
                        t += UInt64(ch - '0')

                        #= Overflow? Test against a conservative limit for simplicity. =#
                        if div(ULLONG_MAX - 10, 10) < parser.content_length
                            parser.header_state = h
                            @err(HPE_INVALID_CONTENT_LENGTH)
                        end
                        parser.content_length = t
                     end

                #= Transfer-Encoding: chunked =#
                elseif h == h_matching_transfer_encoding_chunked
                    parser.index += 1
                    if parser.index > length(CHUNKED) || c != CHUNKED[parser.index]
                        h = h_general
                    elseif parser.index == length(CHUNKED)
                        h = h_transfer_encoding_chunked
                    end

                elseif h == h_matching_connection_token_start
                    #= looking for 'Connection: keep-alive' =#
                    if c == 'k'
                        h = h_matching_connection_keep_alive
                    #= looking for 'Connection: close' =#
                    elseif c == 'c'
                        h = h_matching_connection_close
                    elseif c == 'u'
                        h = h_matching_connection_upgrade
                    elseif tokens[Int(c)+1] > 0
                        h = h_matching_connection_token
                    elseif c == ' ' || c == '\t'
                    #= Skip lws =#
                    else
                        h = h_general
                    end
                #= looking for 'Connection: keep-alive' =#
                elseif h == h_matching_connection_keep_alive
                    parser.index += 1
                    if parser.index > length(KEEP_ALIVE) || c != KEEP_ALIVE[parser.index]
                        h = h_matching_connection_token
                    elseif parser.index == length(KEEP_ALIVE)
                        h = h_connection_keep_alive
                    end

                #= looking for 'Connection: close' =#
                elseif h == h_matching_connection_close
                    parser.index += 1
                    if parser.index > length(CLOSE) || c != CLOSE[parser.index]
                        h = h_matching_connection_token
                    elseif parser.index == length(CLOSE)
                        h = h_connection_close
                    end

                #= looking for 'Connection: upgrade' =#
                elseif h == h_matching_connection_upgrade
                    parser.index += 1
                    if parser.index > length(UPGRADE) || c != UPGRADE[parser.index]
                        h = h_matching_connection_token
                    elseif parser.index == length(UPGRADE)
                        h = h_connection_upgrade
                    end

                elseif h == h_matching_connection_token
                    if ch == ','
                        h = h_matching_connection_token_start
                        parser.index = 1
                    end

                elseif h == h_transfer_encoding_chunked
                    if ch != ' '
                        h = h_general
                    end

                elseif h in (h_connection_keep_alive, h_connection_close, h_connection_upgrade)
                    if ch == ','
                        if (h == h_connection_keep_alive)
                            parser.flags |= F_CONNECTION_KEEP_ALIVE
                        elseif h == h_connection_close
                            parser.flags |= F_CONNECTION_CLOSE
                        elseif h == h_connection_upgrade
                            parser.flags |= F_CONNECTION_UPGRADE
                        end
                        h = h_matching_connection_token_start
                        parser.index = 1
                    elseif ch != ' '
                        h = h_matching_connection_token
                    end

                else
                    p_state = s_header_value
                    h = h_general
                end
                p += 1
            end
            parser.header_state = h

            @nread(p - start)

            if p == len
                p -= 1
            end

        elseif p_state == s_header_almost_done
            @debug(DEBUG, ParsingStateCode(p_state))
            @errorif(ch != LF, HPE_LF_EXPECTED)
            p_state = s_header_value_lws

        elseif p_state == s_header_value_lws
            @debug(DEBUG, ParsingStateCode(p_state))
            if ch == ' ' || ch == '\t'
                p_state = s_header_value_start
                @goto reexecute
            end
            #= finished the header =#
            if parser.header_state == h_connection_keep_alive
                parser.flags |= F_CONNECTION_KEEP_ALIVE
            elseif parser.header_state == h_connection_close
                parser.flags |= F_CONNECTION_CLOSE
            elseif parser.header_state == h_transfer_encoding_chunked
                parser.flags |= F_CHUNKED
            elseif parser.header_state == h_connection_upgrade
                parser.flags |= F_CONNECTION_UPGRADE
            end

            p_state = s_header_field_start
            @goto reexecute

        elseif p_state == s_header_value_discard_ws_almost_done
            @debug(DEBUG, ParsingStateCode(p_state))
            @strictcheck(ch != LF)
            p_state = s_header_value_discard_lws

        elseif p_state == s_header_value_discard_lws
            @debug(DEBUG, ParsingStateCode(p_state))
            if ch == ' ' || ch == '\t'
                p_state = s_header_value_discard_ws
            else
                if parser.header_state == h_connection_keep_alive
                    parser.flags |= F_CONNECTION_KEEP_ALIVE
                elseif parser.header_state == h_connection_close
                    parser.flags |= F_CONNECTION_CLOSE
                elseif parser.header_state == h_connection_upgrade
                    parser.flags |= F_CONNECTION_UPGRADE
                elseif parser.header_state == h_transfer_encoding_chunked
                    parser.flags |= F_CHUNKED
                end

                #= header value was empty =#
                header_value_mark = p
                p_state = s_header_field_start
                parser.state = p_state
                onheadervalue(r, bytes, header_value_mark, p, issetcookie)
                header_value_mark = 0
                @goto reexecute
            end

        elseif p_state == s_headers_almost_done
            @debug(DEBUG, ParsingStateCode(p_state))
            @strictcheck(ch != LF)
            if (parser.flags & F_TRAILING
                ) > 0
                #= End of a chunked request =#
                p_state = s_message_done
                # CALLBACK_NOTIFY_NOADVANCE(chunk_complete)
                @goto reexecute
            end

            #= Cannot use chunked encoding and a content-length header together
            per the HTTP specification. =#
            @errorif((parser.flags & F_CHUNKED) > 0 && (parser.flags & F_CONTENTLENGTH) > 0, HPE_UNEXPECTED_CONTENT_LENGTH)

            p_state = s_headers_done

            #= Set this here so that on_headers_complete() callbacks can see it =#
            upgrade = ((parser.flags & (F_UPGRADE | F_CONNECTION_UPGRADE)) > 0 ==
            (F_UPGRADE | F_CONNECTION_UPGRADE) > 0 ||
            r.method == CONNECT)

            #= Here we call the headers_complete callback. This is somewhat
            * different than other callbacks because if the user returns 1, we
            * will interpret that as saying that this message has no body. This
            * is needed for the annoying case of recieving a response to a HEAD
            * request.
            *
            * We'd like to use CALLBACK_NOTIFY_NOADVANCE() here but we cannot, so
            * we have to simulate it by handling a change in errno below.
            =#
            onheaderscomplete(r)
            # r = settings.on_headers_complete(parser)
            if method == HEAD
                parser.flags |= F_SKIPBODY
            elseif method == CONNECT
                upgrade = true
            end

            @goto reexecute

        elseif p_state == s_headers_done
            @debug(DEBUG, ParsingStateCode(p_state))
            @strictcheck(ch != LF)

            parser.nread = UInt32(0)

            hasBody = parser.flags & F_CHUNKED > 0 ||
                (parser.content_length > 0 && parser.content_length != ULLONG_MAX)
            if upgrade && (r.method == CONNECT ||
                                  (parser.flags & F_SKIPBODY) > 0 || !hasBody)
                #= Exit, the rest of the message is in a different protocol. =#
                p_state = ifelse(http_should_keep_alive(parser, r), start_state, s_dead)
                parser.state = p_state
                onmessagecomplete(r)
                return errno, true, true
            end

            if parser.flags & F_SKIPBODY > 0
                p_state = ifelse(http_should_keep_alive(parser, r), start_state, s_dead)
                parser.state = p_state
                onmessagecomplete(r)
                return errno, true, true
            elseif parser.flags & F_CHUNKED > 0
                #= chunked encoding - ignore Content-Length header =#
                p_state = s_chunk_size_start
            else
                if parser.content_length == 0
                    #= Content-Length header given but zero: Content-Length: 0\r\n =#
                    p_state = ifelse(http_should_keep_alive(parser, r), start_state, s_dead)
                    parser.state = p_state
                    onmessagecomplete(r)
                    return errno, true, true
                elseif parser.content_length != ULLONG_MAX
                    #= Content-Length header given and non-zero =#
                    p_state = s_body_identity
                    @debug(DEBUG, ParsingStateCode(p_state))
                else
                    if !http_message_needs_eof(parser, r)
                        #= Assume content-length 0 - read the next =#
                        p_state = ifelse(http_should_keep_alive(parser, r), start_state, s_dead)
                        parser.state = p_state
                        onmessagecomplete(r)
                        return errno, true, true
                    else
                        #= Read body until EOF =#
                        p_state = s_body_identity_eof
                        @debug(DEBUG, ParsingStateCode(p_state))
                    end
                end
            end

        elseif p_state == s_body_identity
            @debug(DEBUG, ParsingStateCode(p_state))
            to_read = UInt64(min(parser.content_length, len - p + 1))

            assert(parser.content_length != 0
                && parser.content_length != ULLONG_MAX)

            #= The difference between advancing content_length and p is because
            * the latter will automaticaly advance on the next loop iteration.
            * Further, if content_length ends up at 0, we want to see the last
            * byte again for our message complete callback.
            =#
            body_mark = p
            parser.content_length -= to_read
            p += to_read - 1

            if parser.content_length == 0
                p_state = s_message_done

                #= Mimic CALLBACK_DATA_NOADVANCE() but with one extra byte.
                *
                * The alternative to doing this is to wait for the next byte to
                * trigger the data callback, just as in every other case. The
                * problem with this is that this makes it difficult for the test
                * harness to distinguish between complete-on-EOF and
                * complete-on-length. It's not clear that this distinction is
                * important for applications, but let's keep it for now.
                =#
                onbody(r, bytes, body_mark, p)
                body_mark = 0
                # CALLBACK_DATA_(body, p - body_mark + 1, p - data)
                @goto reexecute
            end

        #= read until EOF =#
        elseif p_state == s_body_identity_eof
            @debug(DEBUG, ParsingStateCode(p_state))
            body_mark = p
            p = len - 1 # TODO: maybe not - 1?

        elseif p_state == s_message_done
            @debug(DEBUG, ParsingStateCode(p_state))
            p_state = ifelse(http_should_keep_alive(parser, r), start_state, s_dead)
            parser.state = p_state
            onmessagecomplete(r)
            if upgrade
                #= Exit, the rest of the message is in a different protocol. =#
                parser.state = p_state
                return errno, true, true
            end

        elseif p_state == s_chunk_size_start
            @debug(DEBUG, ParsingStateCode(p_state))
            assert(parser.nread == 1)
            assert(parser.flags & F_CHUNKED > 0)

            unhex_val = unhex[Int(ch)+1]
            @errorif(unhex_val == -1, HPE_INVALID_CHUNK_SIZE)

            parser.content_length = unhex_val
            p_state = s_chunk_size

        elseif p_state == s_chunk_size
            @debug(DEBUG, ParsingStateCode(p_state))
            assert(parser.flags & F_CHUNKED > 0)
            if ch == CR
                p_state = s_chunk_size_almost_done
            else
                unhex_val = unhex[Int(ch)+1]

                if unhex_val == -1
                    if ch == ';' || ch == ' '
                        p_state = s_chunk_parameters
                        @goto breakout
                    end
                    @err(HPE_INVALID_CHUNK_SIZE)
                end
                t = parser.content_length
                t *= UInt64(16)
                t += UInt64(unhex_val)

                #= Overflow? Test against a conservative limit for simplicity. =#
                if div(ULLONG_MAX - 16, 16) < parser.content_length
                    @err(HPE_INVALID_CONTENT_LENGTH)
                end
                parser.content_length = t
            end

        elseif p_state == s_chunk_parameters
            @debug(DEBUG, ParsingStateCode(p_state))
            assert(parser.flags & F_CHUNKED > 0)
            #= just ignore this shit. TODO check for overflow =#
            if ch == CR
                p_state = s_chunk_size_almost_done
            end

        elseif p_state == s_chunk_size_almost_done
            @debug(DEBUG, ParsingStateCode(p_state))
            assert(parser.flags & F_CHUNKED > 0)
            @strictcheck(ch != LF)

            parser.nread = 0

            if parser.content_length == 0
                parser.flags |= F_TRAILING
                p_state = s_header_field_start
            else
                p_state = s_chunk_data
            end
            # CALLBACK_NOTIFY(chunk_header)

        elseif p_state == s_chunk_data
            @debug(DEBUG, ParsingStateCode(p_state))
            to_read = UInt64(min(parser.content_length, len - p + 1))

            assert(parser.flags & F_CHUNKED > 0)
            assert(parser.content_length != 0 && parser.content_length != ULLONG_MAX)

            #= See the explanation in s_body_identity for why the content
            * length and data pointers are managed this way.
            =#
            body_mark = p
            parser.content_length -= to_read
            p += to_read - 1

            if parser.content_length == 0
                p_state = s_chunk_data_almost_done
            end

        elseif p_state == s_chunk_data_almost_done
            @debug(DEBUG, ParsingStateCode(p_state))
            assert(parser.flags & F_CHUNKED > 0)
            assert(parser.content_length == 0)
            @strictcheck(ch != CR)
            p_state = s_chunk_data_done
            onbody(r, bytes, body_mark, p - 1)
            body_mark = 0

        elseif p_state == s_chunk_data_done
            @debug(DEBUG, ParsingStateCode(p_state))
            assert(parser.flags & F_CHUNKED > 0)
            @strictcheck(ch != LF)
            parser.nread = 0
            p_state = s_chunk_size_start
            # CALLBACK_NOTIFY(chunk_complete)

        else
            error("unhandled state")
        end
        @label breakout
        p += 1
    end

    #= Run callbacks for any marks that we have leftover after we ran our of
     * bytes. There should be at most one of these set, so it's OK to invoke
     * them in series (unset marks will not result in callbacks).
     *
     * We use the NOADVANCE() variety of callbacks here because 'p' has already
     * overflowed 'data' and this allows us to correct for the off-by-one that
     * we'd otherwise have (since CALLBACK_DATA() is meant to be run with a 'p'
     * value that's in-bounds).
     =#

    assert(((header_field_mark > 0 ? 1 : 0) +
            (header_value_mark > 0 ? 1 : 0) +
            (url_mark > 0 ? 1 : 0)  +
            (body_mark > 0 ? 1 : 0) +
            (status_mark > 0 ? 1 : 0)) <= 1)

    header_field_mark > 0 && onheaderfield(parser, bytes, header_field_mark, p)
    header_value_mark > 0 && onheadervalue(parser, bytes, header_value_mark, p)
    url_mark > 0 && onurl(r, bytes, url_mark, p)
    body_mark > 0 && onbody(r, bytes, body_mark, p)
    status_mark > 0 && onstatus(r, bytes, status_mark, p)

    parser.state = p_state
    return errno, p_state >= s_headers_done, false

    @label error
    if errno == HPE_OK
        errno = HPE_UNKNOWN
    end

    parser.state = p_state
    return errno, false, false
end

#= Does the parser need to see an EOF to find the end of the message? =#
http_message_needs_eof(parser, r::Request) = false
function http_message_needs_eof(parser, r::Response)
    #= See RFC 2616 section 4.4 =#
    if (div(r.status, 100) == 1 || #= 1xx e.g. Continue =#
        r.status == 204 ||     #= No Content =#
        r.status == 304 ||     #= Not Modified =#
        parser.flags & F_SKIPBODY > 0)       #= response to a HEAD request =#
        return false
    end

    if (parser.flags & F_CHUNKED > 0) || parser.content_length != ULLONG_MAX
        return false
    end

    return true
end

function http_should_keep_alive(parser, r)
    if r.major > 0 && r.minor > 0
        #= HTTP/1.1 =#
        if parser.flags & F_CONNECTION_CLOSE > 0
            return false
        end
    else
        #= HTTP/1.0 or earlier =#
        if !(parser.flags & F_CONNECTION_KEEP_ALIVE > 0)
            return false
        end
    end

  return !http_message_needs_eof(parser, r)
end