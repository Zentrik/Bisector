using Downloads, CodecZlib, Tar, GitHub
using HTTP, JSON3

function get_binaryurl(sha)
    url = "https://buildkite.com/julialang/julia-master/builds?commit=$sha"

    r = HTTP.get(url)
    html = String(r.body)

    build_num = match(r"julialang/julia-master/builds/(\d+)", html).captures[1]

    # Could get job using https://buildkite.com/julialang/julia-master/builds/31230.json instead
    build_url = "https://buildkite.com/" * match(r"julialang/julia-master/builds/\d+", html).match * "/waterfall"
    r = HTTP.get(build_url)
    html = String(r.body)

    job_url = match(Regex("""href="(.+)"><span title=":linux: build x86_64-linux-gnu">"""), html).captures[1]
    job = split(job_url, '#')[2]

    artifacts_url = "https://buildkite.com/organizations/julialang/pipelines/julia-master/builds/$build_num/jobs/$job/artifacts"
    return "https://buildkite.com/" * (HTTP.get(artifacts_url).body |> JSON3.read)[1].url
end

function run_commit(file, commit)
    binary_url = get_binaryurl(commit)
    download_path = Downloads.download(binary_url)

    result = mktempdir() do binary_dir
        # extract
        open(download_path) do io
            stream = GzipDecompressorStream(io)
            Tar.extract(stream, binary_dir)
        end

        read(Cmd(
            `$binary_dir/julia-$(commit[1:10])/bin/julia --project=$binary_dir -E include\(\"$(file[1])\"\)`,
            ignorestatus=true
            ), String
        )
    end

    parse(Float64, result)
end

function bisect_perf(bisect_command, start_sha, end_sha; factor=1.5)
    julia_repo = repo(Repo("JuliaLang/julia"))
    commit_range = map(x->x.sha, compare(julia_repo, start_sha, end_sha).commits)
    push!(commit_range, start_sha)

    # Test script, makes it easy to run bisect command
    file = mktemp()
    write(file[1], bisect_command)

    original_time = run_commit(file, start_sha)
    printstyled("Starting commit took $original_time\n", color=:red)

    end_time = run_commit(file, end_sha)
    printstyled("End commit took $end_time\n", color=:red)

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

        result = try
            run_commit(file, commit)
        catch
            push!(failed_commits, commit)
            deleteat!(commit_range, i)
            right = right - 1
            continue
        end

        printstyled("Commit $commit " * ((result <= factor * original_time) ? "succeeded" : "failed") * " in $result\n", color=:red)

        if result <= factor * original_time
            left = i + 1
        else
            right = i
        end
    end

    return commit_range[left], failed_commits
end

bisect_command = raw"""
ENV["JULIA_PKG_PRECOMPILE_AUTO"] = 0

using Pkg, Test
Pkg.add("Chairmarks")
t = @timed try
    Pkg.test("Chairmarks")
catch
end
t.time
"""
bisect_perf(bisect_command, "427da5c38ee08ab8477f2cd706c605d2d0bcb84c", "fb71a5d2fb6ed8348e3b8ff7b54f18965b9d8d7b")