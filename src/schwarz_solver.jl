function schwarz_solve(modelgraph::ModelGraph,subgraphs::Vector{ModelGraph};
    sub_optimizer = with_optimizer(Ipopt.Optimizer,tol = 1e-8,print_level = 0),
    max_iterations = 100,
    tolerance = 1e-6,
    primal_links = [],
    dual_links = [])

end

#Serial Schwarze Algorithm Implementation
function schwarz_solve(modelgraph::ModelGraph,overlap::Int64;
    sub_optimizer = with_optimizer(Ipopt.Optimizer,tol = 1e-8,print_level = 0),
    max_iterations = 100,
    tolerance = 1e-6,
    primal_links = [],
    dual_links = [])

    #NOTE: Ideally, use a copy of the model graph, or revert changes to modelgrpah
    #copy_mg,copy_map = copy(mg)

    #Check that modelgraph has subgraphs.  If not, raise error.  #Each subgraph will be used to create the subproblems we solve
    has_subgraphs(modelgraph) || error("ModelGraph does not contains any subgraph structure.  Consider creating partitions using a graph partitioner.
    See Documentation for details on how to do this.")

    #Initialize Vectors
    x_vals = Vector{Float64}()  #Primal values for communication
    l_vals = Vector{Float64}()  #Dual values for communication
    ext_var_index_map = Dict{VariableRef,Int64}()  #map boundary variables to indices

    #Map nodes to their orignal subgraphs
    original_subgraphs = modelgraph.subgraphs
    node_subgraph_map = Dict()
    for osub in original_subgraphs
        for node in all_nodes(osub)
            node_subgraph_map[node] = osub
        end
    end

    println("Expanding subgraph domains...")
    #Created expanded subgraphs.  Also return the boundary edges of these expanded subgraphs
    subgraphs,subgraph_boundary_edges = _expand_subgraphs(modelgraph,overlap) #expand_subgraphs.  TODO: Fix bug with zero overlap

    primal_links,dual_links = _assign_links(subgraphs,subgraph_boundary_edges,primal_links,dual_links)
    #subgraph_in_edges,subgraph_out_edges = _get_edge_directions(subgraphs,subgraph_boundary_edges)

    println("Preparing subproblems...")
    #Map subproblems to their original (non-expanded) subgraphs
    subproblems = combine.(subgraphs)
    subproblem_subgraph_map = Dict()
    for i = 1:length(subproblems)
        subproblem = subproblems[i]
        subproblem_subgraph_map[original_subgraphs[i]] = subproblem
    end

    #Initialize subproblem vectors
    x_in_indices = Dict{ModelNode,Vector{Int64}}()   #map subproblem to its x_in_indices
    l_in_indices = Dict{ModelNode,Vector{Int64}}()
    x_out_indices = Dict{ModelNode,Vector{Int64}}()
    l_out_indices = Dict{ModelNode,Vector{Int64}}()
    for (sub,ref) in subproblems
        x_in_indices[sub] = Int64[]
        x_out_indices[sub] = Int64[]
        l_in_indices[sub] = Int64[]
        l_out_indices[sub] = Int64[]
    end
    #Subproblem outputs
    x_out_vals = Dict{ModelNode,Vector{Float64}}()
    l_out_vals = Dict{ModelNode,Vector{Float64}}()

    #INITIALIZE SUBPROBLEM DATA
    _setup_subproblems!(subproblems,x_out_vals,l_out_vals,sub_optimizer)

    #TODO: Condense inputs into data structure
    println("Modifying subproblems...")

    # _modify_subproblems!(modelgraph,subproblems,x_vals,x_in_indices,x_out_indices,l_vals,l_in_indices,l_out_indices,node_subgraph_map,subproblem_subgraph_map,
    # subgraph_in_edges,subgraph_out_edges,ext_var_index_map)#,external_var_map)

    _modify_subproblems!(modelgraph,subproblems,x_vals,x_in_indices,x_out_indices,l_vals,l_in_indices,l_out_indices,node_subgraph_map,subproblem_subgraph_map,
    primal_links,dual_links,ext_var_index_map)

    #Get original linkconstraints that connect subgraphs
    original_linkcons = getlinkconstraints(modelgraph)
    graph_obj = sum(objective_function(node) for node in all_nodes(modelgraph))

    #START THE ALGORITHM
    println("Start algorithm...")
    err_pr = Inf
    err_du = Inf
    #err_save = []
    modelgraph.obj_dict[:err_save] = []
    modelgraph.obj_dict[:objective_iters] = []

    # Initialize primal and dual information for each subproblem
    iteration = 0
    #@printf("Iteration: %4i Prf: %7.2e Duf: %7.2e\n",cnt,err_pr,err_du)
    while err_pr > tolerance || err_du > tolerance
        iteration += 1
        if iteration > max_iterations
            return :MaxIterationReached
        end

        #Do iteration for each subproblem
        for (subproblem,submap) in subproblems  #each subproblem is a ModelNode

            #Get primal and dual information for this subproblem
            x_in_inds = x_in_indices[subproblem]
            l_in_inds = l_in_indices[subproblem]

            x_in = x_vals[x_in_inds]
            l_in = l_vals[l_in_inds]

            #TODO: Parallel do_iteration using remote subproblems
            xk,lk = do_iteration(subproblem,x_in,l_in)  #return primal and dual information we need to communicate to other subproblems

            #Update primal and dual information for other subproblems.  Use restriction to make sure we grab the right values
            x_out_vals[subproblem] = xk    #Update primal info we need to communicate to other subproblems
            l_out_vals[subproblem] = lk    #Update dual info we need to communicate to other subproblems
        end

        #Now update x_in_vals and l_in_vals for the subproblems to send information to
        for (subprob,vals) in x_out_vals
            x_out_inds = x_out_indices[subprob]
            x_vals[x_out_inds] .= vals
        end

        for (subprob,vals) in l_out_vals
            l_out_inds = l_out_indices[subprob]
            l_vals[l_out_inds] .= vals
        end

        #Update graph solution only for nodes in original subgraphs.  Used to calculate residual
        _update_graph_solution!(modelgraph,subproblem_subgraph_map,node_subgraph_map)

        #Check primal and dual feasibility.  Evaluate original partitioned link constraints (i.e. do the restriction) based on direction
        prf = [nodevalue(linkcon.func) for linkcon in original_linkcons]
        duf = []
        for edge in modelgraph.linkedges
            #linkrefs = edge.linkconstraints
            linkcons = getlinkconstraints(edge)

            #for linkref in linkrefs
            for linkcon in linkcons
                #linkcon = modelgraph.linkconstraints[linkref.idx]
                nodes = getnodes(linkcon)
                lambdas = []
                for node in nodes
                    subgraph = node_subgraph_map[node]
                    subproblem,sub_map = subproblem_subgraph_map[subgraph]
                    l_val = dual(sub_map.linkconstraintmap[linkcon])
                    push!(lambdas,l_val)
                end
                #TODO: Correctly calculate dual resiudal.  This only works for simple overlaps
                dual_res = lambdas[1] - lambdas[2]
                push!(duf,dual_res)
            end

        end

        for (subproblem,submap) in subproblems
            JuMP.set_start_value.(all_variables(subproblem),value.(all_variables(subproblem)))
        end

        err_pr = norm(prf[:],Inf)
        err_du = norm(duf[:],Inf)
        obj = nodevalue(graph_obj)

        @printf("%4i %7.2e %7.2e %7.2e\n",iteration,obj,err_pr,err_du)
        push!(modelgraph.obj_dict[:err_save],[err_pr err_du])
        push!(modelgraph.obj_dict[:objective_iters],obj)
    end

    return :Optimal
end

function do_iteration(node::ModelNode,x_in::Vector{Float64},l_in::Vector{Float64})

    update_values!(node,x_in,l_in)  #update x_in and l_in

    optimize!(node) #optimize a subproblem

    #Update start point for next iteration
    term_status = termination_status(node)
    #!(term_status in [MOI.TerminationStatusCode(4),MOI.TerminationStatusCode(1)])  && error("Suboptimal solution detected for problem $node with status $term_status")
    has_values(getmodel(node)) || error("Suboptimal solution detected for problem $node with status $term_status")
    #return values we need to communicate to
    x_out = node.ext[:x_out]    #primal variables to communicate along in edges
    l_out = node.ext[:l_out]    #dual variables to communicate along out edges

    #get variable values
    xk = value.(x_out)

    #println(l_out)
    lk = dual.(l_out)

    return xk, lk
end

function update_values!(node::ModelNode,x_in::Vector{Float64},l_in::Vector{Float64})
    #set primal values
    for (i,var) in enumerate(node.ext[:x_in]) #make sure x_in and node.ext[:x_in] match up
        fix(var,x_in[i])
    end
    obj_original = node.ext[:original_objective]
    obj = obj_original

    funcs = GenericAffExpr{Float64,VariableRef}[]
    for (i,con) in enumerate(node.ext[:l_in])
        func = l_in[i]*node.ext[:lmap][con]
        push!(funcs,func)
    end
    set_objective_function(getmodel(node),obj_original - sum(funcs)) #sum(l_in[i]*funcs[i] for i = 1:length(funcs)))
    return nothing
end

################################################
#SCHWARZ PROTOTYPE SOLVER UTILITY FUNCTIONS
################################################
# #NOTE: This might be causing issues
# function _get_edge_directions(subgraphs,subgraph_boundary_edges)
#     #Each subgraph has outgoing and incoming edges(constraints). That is, we have bidirectional couplings
#     subgraph_out_edges = [] #[[],[],[]]  #receive dual info from out edges
#     subgraph_in_edges = []  #[[],[],[]]  #receive primal info from in edges
#     #Let's assume that constraints go to the last node in the set.  We can make it possible to provide this mapping later.
#     for (i,edge_set) in enumerate(subgraph_boundary_edges)
#         out_edges = LinkEdge[]
#         in_edges = LinkEdge[]
#         for edge in edge_set
#             target_node = collect(edge.nodes)[end]
#             if !(target_node in subgraphs[i].modelnodes)
#                 push!(out_edges,edge)  #send primal info to target node, receive dual info
#             else
#                 push!(in_edges,edge)   #receive primal info at target node, send back dual info
#             end
#         end
#         push!(subgraph_out_edges,out_edges)
#         push!(subgraph_in_edges,in_edges)
#     end
#     return subgraph_in_edges,subgraph_out_edges
# end
function _assign_links(subgraphs,subgraph_boundary_edges,input_primal_links,input_dual_links)
    subgraph_primal_links = []
    subgraph_dual_links = []

    for (i,edge_set) in enumerate(subgraph_boundary_edges)
        primal_links = LinkConstraintRef[] #LinkEdge[]
        dual_links = LinkConstraintRef[]   #LinkEdge[]

        for edge in edge_set
            linkrefs = edge.linkrefs
            for linkref in linkrefs
                if linkref in input_primal_links
                    push!(primal_links,linkref)
                elseif linkref in input_dual_links
                    push!(dual_links,linkref)
                else
                    target_node = collect(edge.nodes)[end]
                    if !(target_node in subgraphs[i].modelnodes)
                        push!(dual_links,linkref)  #send primal info to target node, receive dual info
                    else
                        push!(primal_links,linkref)   #receive primal info at target node, send back dual info
                    end
                end
            end
        end
        push!(subgraph_primal_links,primal_links)
        push!(subgraph_dual_links,dual_links)
        # push!(subgraph_out_edges,out_edges)
        # push!(subgraph_in_edges,in_edges)
    end
    return subgraph_primal_links,subgraph_dual_links
end

#Create schwarz subproblems
function _setup_subproblems!(subproblems,x_out_vals,l_out_vals,optimizer)
    for (subproblem,ref_map) in subproblems
        x_out_vals[subproblem] = Float64[]
        l_out_vals[subproblem] = Float64[]
        #Primal data
        subproblem.ext[:x_in] = VariableRef[]                        #variables into subproblem
        subproblem.ext[:x_out] = VariableRef[]                       #variables out of subproblem
        subproblem.ext[:varmap] = Dict{VariableRef,VariableRef}()    #map subgraph variables to created subproblem variables
        subproblem.ext[:added_constraints] = ConstraintRef[]         #link constraints added to this subproblem

        #Dual data
        subproblem.ext[:l_in] = LinkConstraint[]                     #duals into subproblem
        subproblem.ext[:l_out] = ConstraintRef[]                     #duals out of subproblem
        subproblem.ext[:lmap] = Dict{LinkConstraint,GenericAffExpr{Float64,VariableRef}}()  #map linkconstraints to objective penalty terms

        obj = objective_function(subproblem)
        subproblem.ext[:original_objective] = obj

        JuMP.set_optimizer(getmodel(subproblem),optimizer)
    end
    return nothing
end

# function _modify_subproblems!(modelgraph,subproblems,x_vals,x_in_indices,x_out_indices,l_vals,l_in_indices,l_out_indices,node_subgraph_map,subproblem_subgraph_map,
#     subgraph_in_edges,subgraph_out_edges,ext_var_index_map)
function _modify_subproblems!(modelgraph,subproblems,x_vals,x_in_indices,x_out_indices,l_vals,l_in_indices,l_out_indices,node_subgraph_map,subproblem_subgraph_map,
    primal_links,dual_links,ext_var_index_map)
    for i = 1:length(subproblems)
        subproblem,submap = subproblems[i]  #get the corresponding subproblem

        # figure out primal and dual links
        # in_edges = subgraph_in_edges[i]
        # out_edges = subgraph_out_edges[i]

        for linkref in dual_links[i]
            edge = linkref.linkedge
            #link = constraint_object(linkref)
            link = linkref.linkedge.linkconstraints[linkref.idx]
            # link_idx = linkref.idx
            # link = edge.linkconstraints[link_idx]

        #for edge in out_edges
            # for link in getlinkconstraints(edge)

            if !(haskey(edge.dual_values,link))
                edge.dual_values[link] = 0.0
            end

            #INPUTS
            if edge.dual_values[link] != nothing
                push!(l_vals,edge.dual_values[link])
            else
                push!(l_vals,0.0)  #initial dual value
            end

            idx = length(l_vals)
            push!(l_in_indices[subproblem],idx)                                      #add index to subproblem l inputs

            #OUTPUTS
            #NOTE: This doesn't make sense anymore without edge directions
            #external_node = getnodes(link)[end]

            vars = collect(keys(link.func.terms))                                   #variables in linkconsstraint
            external_vars = [var for var in vars if !(var in keys(submap.varmap))]
            external_node = getnode(external_vars[end])

                                                                                      #get the target node for this link
            target_subgraph = node_subgraph_map[external_node]                        #get the restricted subgraph
            target_subproblem_map = subproblem_subgraph_map[target_subgraph]          #the subproblem that owns this link_constraint
            target_subproblem,target_map = target_subproblem_map
            push!(l_out_indices[target_subproblem],idx)                               #add index to target subproblem outputs
            push!(target_subproblem.ext[:l_out],target_map.linkconstraintmap[link])   #map linkconstraint to target subproblem dual outputs
            _add_subproblem_dual_penalty!(subproblem,submap.varmap,link,l_vals[idx])  #Add penalty to subproblem
        end

        for linkref in primal_links[i]
            edge = linkref.linkedge
            #link = constraint_object(linkref)
            link = linkref.linkedge.linkconstraints[linkref.idx]
            #for edge in in_edges
                # for link in getlinkconstraints(edge)
            vars = collect(keys(link.func.terms))                                   #variables in linkconsstraint
            external_vars = [var for var in vars if !(var in keys(submap.varmap))]  #variables not part of this subproblem

            for ext_var in external_vars
                #if external variable hasn't been counted yet
                if !(ext_var in keys(ext_var_index_map))
                    JuMP.start_value(ext_var) == nothing ? start = 1 : start = JuMP.start_value(ext_var)
                    push!(x_vals,start)                                                 #increment x_vals
                    idx = length(x_vals)                                                #get index
                    ext_var_index_map[ext_var] = idx                                    #map index for external variable

                    external_node = getnode(ext_var)                                    #get the node for this external variable
                    source_subgraph = node_subgraph_map[external_node]                  #get the restricted subgraph
                    source_subproblem_map = subproblem_subgraph_map[source_subgraph]    #get the subproblem that owns this external variable
                    source_subproblem,source_map = source_subproblem_map

                    #OUTPUTS
                    push!(x_out_indices[source_subproblem],idx)                         #add index to source subproblem outputs
                    push!(source_subproblem.ext[:x_out],source_map.varmap[ext_var])     #map external variable to source problem primal outputs
                else
                    idx = ext_var_index_map[ext_var]
                end

                #If this subproblem needs to make a copy of the external variable
                if !(ext_var in keys(subproblem.ext[:varmap]))
                    #we don't always want to make a copy if this subproblem already has a copy of this variable
                    copyvar = _add_subproblem_var!(subproblem,ext_var)                  #create local variable on subproblem
                    #INPUTS
                    push!(x_in_indices[subproblem],idx)
                    #external_var_map[subproblem][ext_var] = copyvar
                end
                # else
                #     copyvar = subproblem.ext[:varmap]
                # end
            end
            mapping = merge(submap.varmap,subproblem.ext[:varmap])
            _add_subproblem_constraint!(subproblem,mapping,link)               #Add link constraint to the subproblem
        end
    end

    return nothing
end

function _update_graph_solution!(modelgraph,subproblem_subgraph_map,node_subgraph_map)
    #update node variable values
    for subgraph in modelgraph.subgraphs
        subproblem,sub_map = subproblem_subgraph_map[subgraph]
        for node in all_nodes(subgraph)
            for var in JuMP.all_variables(node)
                node.variable_values[var] = value(sub_map[var])
            end
        end
    end
    #update link duals with target subgraph
    #NOTE: this doesn't really make sense at the boundaries
    for edge in modelgraph.linkedges
        for linkcon in getlinkconstraints(edge)
            node_end = getnode(collect(keys(linkcon.func.terms))[1])
            subgraph = node_subgraph_map[node_end]
            subproblem,sub_map = subproblem_subgraph_map[subgraph]
            dual_value = dual(sub_map.linkconstraintmap[linkcon])
            edge.dual_values[linkcon] = dual_value
        end
    end

    return nothing
end

function _expand_subgraphs(mg::ModelGraph,overlap::Int64)

    subproblem_graphs = []
    boundary_linkedges_list = []
    #Use modelgraph linkedges to get boundary nodes
    hypergraph,hyper_map = gethypergraph(mg)
    for subgraph in getsubgraphs(mg)

        println("Performing neighborhood expansion...")

        subnodes = all_nodes(subgraph)
        hypernodes = [hyper_map[node] for node in subnodes]
        #Return new hypernodes and hyperedges covered through the expansion.

        overlap_hnodes = Plasmo.neighborhood(hypergraph,hypernodes,overlap)
        overlap_hedges = Plasmo.induced_edges(hypergraph,overlap_hnodes)
        boundary_hedges = Plasmo.incident_edges(hypergraph,overlap_hnodes)

        overlap_nodes = [hyper_map[node] for node in overlap_hnodes]
        overlap_edges = [hyper_map[edge] for edge in overlap_hedges]
        boundary_edges = [hyper_map[edge] for edge in boundary_hedges]

        #Setup subproblem graphs
        subproblem_graph = ModelGraph()
        subproblem_graph.modelnodes = overlap_nodes
        subproblem_graph.linkedges = overlap_edges

        push!(subproblem_graphs,subproblem_graph)
        push!(boundary_linkedges_list,boundary_edges)
    end

    return subproblem_graphs,boundary_linkedges_list
end

function _add_subproblem_var!(subproblem::ModelNode,ext_var::VariableRef)
    newvar = @variable(subproblem)
    JuMP.set_name(newvar,name(ext_var)*"ghost")
    JuMP.start_value(ext_var) == nothing ? start = 1 : start = JuMP.start_value(ext_var)
    JuMP.fix(newvar,start)     #we will fix this to a new value for each iteration
    subproblem.ext[:varmap][ext_var] = newvar
    push!(subproblem.ext[:x_in],newvar)
    return newvar
end

function _add_subproblem_constraint!(subproblem::ModelNode,mapping::Dict,con::LinkConstraint)
    new_con = Plasmo._copy_constraint(con,mapping)
    conref = JuMP.add_constraint(subproblem,new_con)
    push!(subproblem.ext[:added_constraints], conref)
end

function _add_subproblem_dual_penalty!(subproblem::ModelNode,mapping::Dict,con::LinkConstraint,l_start::Float64)

    push!(subproblem.ext[:l_in],con)

    #ignore ghost var in mapping
    vars = collect(keys(con.func.terms))
    local_vars = [var for var in vars if var in keys(mapping)]

    con_func = con.func  #need to create func containing only local vars
    terms = con_func.terms
    new_terms = OrderedDict([(mapping[var_ref],coeff) for (var_ref,coeff) in terms if var_ref in local_vars])
    new_func = JuMP.GenericAffExpr{Float64,JuMP.VariableRef}()
    new_func.terms = new_terms
    new_func.constant = con_func.constant

    subproblem.ext[:lmap][con] = new_func
end
