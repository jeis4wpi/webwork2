define(['backbone','views/SidePane', 'config'],function(Backbone,SidePane,config){
	var LibraryOptionsView = SidePane.extend({
    initialize: function(options){
        var self = this;
        this.problemSets = options.problemSets;
        this.problemSets.on({
            add: this.AddProblemSet, sync: function(_set){               
                self.$(".select-target-option").val(_set.get("set_id"));
                self.model.set({new_problem_set: "",target_set: _set.get("set_id")});
                self.trigger("change-target-set",self.model.get("target_set"));
                self.render();
            },
            remove: function(_set){
                self.model.set({target_set: ""});
                self.trigger("change-target-set","");
            }
        }); 
        this.settings = options.settings;
        this.model = new LibraryOptions({display_option: this.settings.getSettingValue("pg{options}{displayMode}"),
            target_set: "", new_problem_set: "", problemSets: this.problemSets});
        _.extend(this,Backbone.Events);
    },
    render: function(){
        this.$el.html($("#library-options-template").html());
        this.stickit();
        if(this.model.get("target_set")){
            this.$(".goto-problem-set-button").removeAttr("disabled");
        }

        return this;
    }, 
    bindings: {".problem-display-option": {observe: "display_option", selectOptions: {
            collection: function () {
                var modes = this.settings.getSettingValue("pg{displayModes}").slice();
                modes.push("None");
                return modes;
            }
        }},
        ".select-target-option": {observe: "target_set", selectOptions: {
            collection: function () { return this.problemSets.pluck("set_id"); },
            defaultOption: {label: "Select Target...", value: null}
        }},
        ".add-problem-set-option": "new_problem_set"
    },
    events: {
        "change .problem-display-option": function (evt) { this.trigger("change-display-mode", evt);},
        "change .select-target-option": function (evt) {
            this.trigger("change-target-set",evt);
            if($(evt.target).val()===""){
                this.$(".goto-problem-set-button").attr("disabled","disabled")
            } else {
                this.$(".goto-problem-set-button").removeAttr("disabled")
            }
        },
        "click .add-problem-set-button": function () { 
            var msg;
            if(msg = this.model.validate()){
                this.$(".add-problem-set-option").popover({title: "Error", content: msg.new_problem_set, placement: "bottom"})
                    .popover("show");
            } else {
                this.$(".add-problem-set-option").popover("destroy");
                this.trigger("add-problem-set",this.model.get("new_problem_set"));
            }
        },
        "click .show-hide-tags-button" : function (evt) {this.trigger("show-hide-tags",$(evt.target))},
        "click .show-hide-path-button" : function (evt) {this.trigger("show-hide-path",$(evt.target))},
        "click .goto-problem-set-button": function (){ this.trigger("goto-problem-set",this.model.get("target_set"))}
    },
    addProblemSet: function(_set){
        this.model.set("target_set",_set.get("set_id"));
        this.render();
    }
});

var LibraryOptions = Backbone.Model.extend({
    validation: {
        new_problem_set: function(value, attr, computedState) {
            if(_(computedState.problemSets.pluck("set_id")).contains(value)){
                return "The problem set " + value + " already exists.";
            }
        }
    }
});



return LibraryOptionsView;
})