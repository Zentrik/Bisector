using Pkg
Pkg.activate(@__DIR__)
using Downloads, CodecZlib, Tar, GitHub
using HTTP, JSON3

function get_binaryurl(sha, branch)
    url = "https://buildkite.com/julialang/julia-$branch/builds?commit=$sha"

    r = HTTP.get(url)
    html = String(r.body)

    build_num = match(r"julialang/julia-\w*/builds/(\d+)", html).captures[1]

    details_url = "https://buildkite.com/" * match(r"julialang/julia-\w*/builds/\d+", html).match * ".json"
    details_json = HTTP.get(details_url).body |> JSON3.read
    idx = findfirst(x->x.name == ":linux: build x86_64-linux-gnu", details_json.jobs)

    artifacts_url = "https://buildkite.com/" * details_json.jobs[idx].base_path * "/artifacts"

    return "https://buildkite.com" * (HTTP.get(artifacts_url).body |> JSON3.read)[1].url
end

function run_commit(file, commit, branch; download_cache="/home/rag/Documents/Code/Bisector/cached_binaries")
    result = if !isnothing(download_cache)
        if !isdir(download_cache)
            mkpath(download_cache)
        end
        if "julia-$(commit[1:10])" ∉ readdir(download_cache)
            binary_url = get_binaryurl(commit, branch)
            download_path = Downloads.download(binary_url)

            open(download_path) do io
                stream = GzipDecompressorStream(io)
                Tar.extract(stream, joinpath(download_cache, "tmp-julia-$(commit[1:10])"))
                dir = readdir(joinpath(download_cache, "tmp-julia-$(commit[1:10])"), join=True)[1]
                mv(dir, joinpath(download_cache, "julia-$(commit[1:10])")) # Tar doesn't let me extract to a non-empty directory
                rm(joinpath(download_cache, "tmp-julia-$(commit[1:10])"))
            end
        end

        @time x = mktempdir() do project_dir
            read(Cmd(
                `$download_cache/julia-$(commit[1:10])/bin/julia --startup-file=no --project=$download_cache -E include\(\"$(file[1])\"\)`,
                # `$download_cache/julia-$(commit[1:10])/bin/julia --startup-file=no --project=$project_dir -E include\(\"$(file[1])\"\)`,
                ignorestatus=true
                ), String
            )
        end
        x
    else
        binary_url = get_binaryurl(commit, branch)
        download_path = Downloads.download(binary_url)

        mktempdir() do binary_dir
            # extract
            open(download_path) do io
                stream = GzipDecompressorStream(io)
                Tar.extract(stream, binary_dir)
            end

            read(Cmd(
                `$binary_dir/julia-$(commit[1:10])/bin/julia --startup-file=no --project=$binary_dir -E include\(\"$(file[1])\"\)`,
                ignorestatus=true
                ), String
            )
        end
    end

    parse(Float64, result)
end

function bisect_perf(bisect_command, start_sha, end_sha; factor=1.5, branch="master")
    commit_range = map(x->x.sha, compare("JuliaLang/julia", start_sha, end_sha).commits)
    pushfirst!(commit_range, start_sha)

    # Test script, makes it easy to run bisect command
    file = mktemp()
    write(file[1], bisect_command)

    original_time = run_commit(file, start_sha, branch)
    printstyled("Starting commit took $(original_time)ns\n", color=:red)

    end_time = run_commit(file, end_sha, branch)
    printstyled("End commit took $(end_time)ns\n", color=:red)

    if end_time <= factor * original_time
        return
    end

    failed_commits = String[]

    left = 2
    right = length(commit_range)
    i = 0
    while left < right
        i = (left + right) ÷ 2
        commit = commit_range[i]

        result = if commit == end_sha
            end_time
        else
            try
                run_commit(file, commit, branch)
            catch err
                display(err)
                push!(failed_commits, commit)
                deleteat!(commit_range, i)
                right = right - 1
                continue
            end
        end

        printstyled("Commit $commit " * ((result <= factor * original_time) ? "succeeded" : "failed") * " in $(result)ns\n", color=:red)

        if result <= factor * original_time
            left = i + 1
        else
            right = i
        end
    end

    return commit_range[left], failed_commits
end

bisect_command = raw"""
ENV["JULIA_PKG_PRECOMPILE_AUTO"]=0

# using Pkg
# Pkg.update(; level=Pkg.UPLEVEL_FIXED)
# Pkg.add(url="https://github.com/JuliaCI/BaseBenchmarks.jl", io=devnull)

a = BitMatrix(undef, (1000, 1000));
a * a
start_time = time()
a * a
time() - start_time
"""
bisect_perf(bisect_command, "8f5b7ca12ad48c6d740e058312fc8cf2bbe67848", "5e9a32e7af2837e677e60543d4a15faa8d3a7297"; factor=2) |> println